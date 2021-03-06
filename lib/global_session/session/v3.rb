# Copyright (c) 2012 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Standard library dependencies
require 'set'

# SignedHash, which encapsulates the crypto bit of global sessions
require 'right_support/crypto'

module GlobalSession::Session
  # Global session V3 uses JSON serialization, no compression, and a detached signature that is
  # excluded from the JSON structure for efficiency reasons.
  #
  # The binary structure of a V3 session looks like this:
  #  <utf8_json><0x00><binary_signature>
  #
  # Its JSON structure is an Array with the following format:
  #  [<version_integer>,
  #   <uuid_string>,
  #   <signing_authority_string>,
  #   <creation_timestamp_integer>,
  #   <expiration_timestamp_integer>,
  #   {<signed_data_hash>},
  #   {<unsigned_data_hash>}]
  #
  # The design goal of V3 is to ensure broad compatibility across various programming languages
  # and cryptographic libraries, and to create a serialization format that can be reused for
  # future versions. To this end, it sacrifices space efficiency by switching back to JSON
  # encoding (instead of msgpack), and uses the undocumented OpenSSL::PKey#sign and #verify
  # operations which rely on the PKCS7-compliant OpenSSL EVP API.
  class V3 < Abstract
    # Pattern that matches strings that are probably a V3 session cookie.
    HEADER = /^WzM/

    STRING_ENCODING = !!(RUBY_VERSION !~ /1.8/)

    # Utility method to decode a cookie; good for console debugging. This performs no
    # validation or security check of any sort.
    #
    # === Parameters
    # cookie(String):: well-formed global session cookie
    def self.decode_cookie(cookie)
      bin = GlobalSession::Encoding::Base64Cookie.load(cookie)
      json, sig = split_body(bin)
      return GlobalSession::Encoding::JSON.load(json), sig
    end

    # Split an ASCII-8bit input string into two constituent parts: a UTF-8 JSON document
    # and an ASCII-8bit binary string. A null (0x00) separator character is presumed to
    # separate the two parts of the input string.
    #
    # This is an implementation helper for GlobalSession serialization and not useful for
    # the public at large. It's left public as an aid for those who want to hack sessions.
    #
    # @param [String] input a binary string (encoding will be forced to ASCII_8BIT!)
    # @return [Array] returns a 2-element Array of String: json document, plus binary signature
    # @raise [ArgumentError] if the null separator is missing
    def self.split_body(input)
      input.force_encoding(Encoding::ASCII_8BIT) if STRING_ENCODING
      null_at = input.index("\x00")

      if null_at
        json = input[0...null_at]
        sig = input[null_at+1..-1]
        if STRING_ENCODING
          json.force_encoding(Encoding::UTF_8)
          sig.force_encoding(Encoding::ASCII_8BIT)
        end

        return json, sig
      else
        raise ArgumentError, "Malformed input string does not contain 0x00 byte"
      end
    end

    # Join a UTF-8 JSON document and an ASCII-8bit binary string.
    #
    # This is an implementation helper for GlobalSession serialization and not useful for
    # the public at large. It's left public as an aid for those who want to hack sessions.
    #
    # @param [String] json a UTF-8 JSON document (encoding will be forced to UTF_8!)
    # @param [String] signature a binary signautre (encoding will be forced to ASCII_8BIT!)
    # @return [String] a binary concatenation of the two inputs, separated by 0x00
    def self.join_body(json, signature)
      result = ""
      if STRING_ENCODING
        result.force_encoding(Encoding::ASCII_8BIT)
        json.force_encoding(Encoding::ASCII_8BIT)
        signature.force_encoding(Encoding::ASCII_8BIT)
      end

      result << json
      result << "\x00"
      result << signature
      result
    end

    # Serialize the session to a form suitable for use with HTTP cookies. If any
    # secure attributes have changed since the session was instantiated, compute
    # a fresh RSA signature.
    #
    # @return [String] a B64cookie-encoded JSON-serialized global session
    # @raise [GlobalSession::UnserializableType] if the attributes hash contains
    def to_s
      if @cookie && !dirty?
        #use cached cookie if nothing has changed
        return @cookie
      end

      unless serializable?(@signed) && serializable?(@insecure)
        raise GlobalSession::UnserializableType,
              "Attributes hash contains non-String keys, cannot be cleanly marshalled"
      end

      hash = {'v' => 3,
              'id' => @id, 'a' => @authority,
              'tc' => @created_at.to_i, 'te' => @expired_at.to_i,
              'ds' => @signed}

      if @signature && !(@dirty_timestamps || @dirty_secure)
        #use cached signature unless we've changed secure state
        authority = @authority
      else
        authority_check
        authority = @directory.local_authority_name
        hash['a'] = authority
        signed_hash = RightSupport::Crypto::SignedHash.new(
          hash,
          @directory.private_key,
          envelope: true,
          encoding: GlobalSession::Encoding::JSON)
        @signature = signed_hash.sign(@expired_at)
      end

      hash['dx'] = @insecure
      hash['a'] = authority

      array = attribute_hash_to_array(hash)
      json = GlobalSession::Encoding::JSON.dump(array)
      bin = self.class.join_body(json, @signature)
      return GlobalSession::Encoding::Base64Cookie.dump(bin)
    end

    # Return the SHA1 hash of the most recently-computed RSA signature of this session.
    # This isn't really intended for the end user; it exists so the Web framework integration
    # code can optimize request speed by caching the most recently verified signature in the
    # local session and avoid re-verifying it on every request.
    #
    # === Return
    # digest(String):: SHA1 hex-digest of most-recently-computed signature
    def signature_digest
      @signature ? digest(@signature) : nil
    end

    private

    def load_from_cookie(cookie) # :nodoc:
      hash = nil

      begin
        array, signature = self.class.decode_cookie(cookie)
        hash = attribute_array_to_hash(array)
      rescue Exception => e
        mc = GlobalSession::MalformedCookie.new("Caused by #{e.class.name}: #{e.message}", cookie)
        mc.set_backtrace(e.backtrace)
        raise mc
      end

      _ = hash['v']
      id = hash['id']
      authority = hash['a']
      created_at = Time.at(hash['tc'].to_i).utc
      expired_at = Time.at(hash['te'].to_i).utc
      signed = hash['ds']
      insecure = hash.delete('dx')

      #Check trust in signing authority
      if @directory.trusted_authority?(authority)
        signed_hash = RightSupport::Crypto::SignedHash.new(
          hash,
          @directory.authorities[authority],
          :envelope=>true,
          :encoding=>GlobalSession::Encoding::JSON)

        begin
          signed_hash.verify!(signature, expired_at)
        rescue RightSupport::Crypto::ExpiredSignature
          raise GlobalSession::ExpiredSession, "Session expired at #{expired_at}"
        rescue RightSupport::Crypto::InvalidSignature => e
          raise GlobalSession::InvalidSignature, "Global session signature verification failed: " + e.message
        end

      else
        raise GlobalSession::InvalidSignature, "Global sessions signed by #{authority.inspect} are not trusted"
      end

      #Check expiration
      unless expired_at > Time.now.utc
        raise GlobalSession::ExpiredSession, "Session expired at #{expired_at}"
      end

      #Check other validity (delegate to directory)
      unless @directory.valid_session?(id, expired_at)
        raise GlobalSession::InvalidSession, "Global session has been invalidated"
      end

      #If all validation stuff passed, assign our instance variables.
      @id = id
      @authority = authority
      @created_at = created_at
      @expired_at = expired_at
      @signed = signed
      @insecure = insecure
      @signature = signature
      @cookie = cookie
    end

    def create_from_scratch # :nodoc:
      @signed = {}
      @insecure = {}
      @created_at = Time.now.utc
      @authority = @directory.local_authority_name
      @id = RightSupport::Data::UUID.generate
      renew!
    end

    # Transform a V1-style attribute hash to an Array with fixed placement for
    # each element. The V3 scheme is serialized as an array to save space.
    #
    # === Parameters
    # hash(Hash):: the attribute hash
    #
    # === Return
    # attributes(Array)::
    #
    def attribute_hash_to_array(hash)
      [
        hash['v'],
        hash['id'],
        hash['a'],
        hash['tc'],
        hash['te'],
        hash['ds'],
        hash['dx'],
      ]
    end

    # Transform a V2-style attribute array to a Hash with the traditional attribute
    # names. This is good for passing to SignedHash, or initializing a V1 session for
    # downrev compatibility.
    #
    # === Parameters
    # hash(Hash):: the attribute hash
    #
    # === Return
    # attributes(Array):: fixed-position attributes array
    #
    def attribute_array_to_hash(array)
      {
        'v'  => array[0],
        'id' => array[1],
        'a'  => array[2],
        'tc' => array[3],
        'te' => array[4],
        'ds' => array[5],
        'dx' => array[6],
      }
    end

    # Determine whether an object can be cleanly round-tripped to JSON
    # @param [Object] obj
    # @return [Boolean]
    def serializable?(obj)
      case obj
      when Numeric, String, TrueClass, FalseClass, NilClass, Symbol
        true
      when Array
        obj.each { |e| serializable?(e) }
      when Hash
        obj.all? do |k, v|
          k.is_a?(String) && serializable?(v)
        end
      else
        false
      end
    end
  end
end

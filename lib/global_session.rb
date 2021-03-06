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

module GlobalSession
  # Indicates that the global session configuration file is malformatted or missing
  # required fields. Also used as a base class for other errors.
  class ConfigurationError < Exception; end

  # The general category of client-side errors. Used solely as a base class.
  class ClientError < Exception; end

  # Global session configuration is missing from the environment or filesystem.
  #
  class MissingConfiguration < ConfigurationError; end

  # The request has a valid session cookie, but the session ID was reported as
  # invalid by the Directory.
  #
  # See Directory#valid_session? for more information.
  #
  class InvalidSession < ClientError; end

  # The request has a valid session cookie, but the session has expired.
  #
  class ExpiredSession < ClientError; end

  # The request has a valid session cookie, but the session has expired.
  class PrematureSession < ExpiredSession; end

  # The request has a session cookie, but the cookie is malformed and cannot be
  # interpreted as session state.
  #
  class MalformedCookie < ClientError
    attr_reader :cookie

    def initialize(message, cookie=nil)
      if cookie.nil?
        super(message)
      else
        super("(data[0..4]: '%s') - %s" % [cookie[0..4], message])
        @cookie = cookie
      end
    end
  end

  # Indicates that application code tried to put an unserializable object into the glboal
  # session hash. Because the global session is serialized as JSON and not all Ruby types
  # can be easily round-tripped to JSON and back without data loss, we constrain the types
  # that can be serialized.
  #
  # See GlobalSession::Encoding::JSON for more information on serializable types.
  #
  class UnserializableType < ConfigurationError; end

  # Indicates that the application code tried to write a secure session attribute or
  # renew the global session. Both of these operations require a local authority
  # because they require a new signature to be computed on the global session.
  #
  # See GlobalSession::Configuration and GlobalSession::Directory for more
  # information.
  #
  class NoAuthority < ConfigurationError; end

  # The request has a session cookie, but its signature is invalid.
  class InvalidSignature < SecurityError; end
end

#Make sure gem dependencies are activated.
require 'right_support'
require 'json'

#Require Ruby library dependencies
require 'openssl'

#Require the core suite of GlobalSession classes and modules
require 'global_session/configuration'
require 'global_session/keystore'
require 'global_session/directory'
require 'global_session/encoding'
require 'global_session/session'
require 'global_session/rack'

#Preemptively try to activate the Rails plugin
if require_succeeds?('action_pack') &&
   require_succeeds?('action_controller')

  action_pack = Gem.loaded_specs['action_pack'] || Gem.loaded_specs['actionpack']

  # Make sure we are dealing with Rails 2.x, not 3.x
  if action_pack && action_pack.version.to_s =~ /^2\./
    require 'global_session/rails'
  end
end

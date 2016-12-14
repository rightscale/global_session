require 'spec_helper'
require File.expand_path('../shared_examples', __FILE__)

describe 'GlobalSession::Session::V3 with EC crypto' do
  subject { GlobalSession::Session::V3 }

  let(:key_generation_parameter) { 'prime256v1' }
  let(:signature_method) { :dsa_sign_asn1 }
  it_should_behave_like 'all subclasses of Session::Abstract'

  before(:each) do
    mock_config('test/trust', ['authority1'])
    mock_config('test/authority', 'authority1')
    mock_config('common/attributes/signed', ['user'])
    mock_config('common/attributes/insecure', ['favorite_color'])
    @directory        = GlobalSession::Directory.new(mock_config, @key_factory.dir)
    @original_session = subject.new(@directory)
    @cookie           = @original_session.to_s
  end

  context 'cookie size' do
    it 'has size ~208 bytes' do
      size  = 0
      count = 0
      100.times do
        session = subject.new(@directory)
        size += session.to_s.size
        count += 1
      end

      (Float(size) / Float(count)).should be_close(208, 5)
    end
  end

  context '#delete' do
    context 'when the key is insecure' do
      before(:each) do
        @original_session['favorite_color'] = 'bar'
      end

      it 'removes the key from the session' do
        @original_session.delete('favorite_color')
        @original_session['favorite_color'].should be_nil
      end
    end

    context 'when the key is signed' do
      before(:each) do
        @original_session['user'] = 'bar'
      end

      it 'removes the key from the session' do
        @original_session.delete('user')
        @original_session['user'].should be_nil
      end
    end

    context 'when the key does not exist in the session' do
      it 'raises ArgumentError' do
        expect {
          @original_session.delete('foo')
        }.to raise_error(ArgumentError)
      end
    end
  end

  context '#clone' do
    before(:each) do
      @original_session['user'] = 'bar'
    end

    it 'is not destructive to the original session' do
      new_session = @original_session.clone
      new_session.delete('user')
      @original_session['user'].should == 'bar'
    end
  end

  context '#to_s' do
    context 'when the session contains unserializable keys' do
      before(:each) do
        @original_session['user'] = {1=>[2,3]}
      end

      it 'raises UnserializableType' do
        expect {
          @original_session.to_s
        }.to raise_error(GlobalSession::UnserializableType)
      end
    end
  end

  context 'JSON Web Token interoperability' do
    before(:all) do
      require 'jwt'
    end

    it 'uses JWT-compatible ECDSA keys' do
      authority = @directory.keystore.private_key_name
      priv = @directory.keystore.private_key
      pub = @directory.keystore.public_keys[authority]
      payload = {'sub' => 'joe schmoe'}
      token = JWT.encode payload, priv, 'ES256'
      jwt, jws = JWT.decode token, pub, true, algorithm: 'ES256'
      jwt.should == payload
    end
  end
end
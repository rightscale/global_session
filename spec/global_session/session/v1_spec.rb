require 'spec_helper'
require File.expand_path('../shared_examples', __FILE__)

describe GlobalSession::Session::V1 do
  subject { GlobalSession::Session::V1 }

  let(:signature_method) { :private_encrypt }
  let(:approximate_token_size) { 340 }

  it_should_behave_like 'all subclasses of Session::Abstract'
end

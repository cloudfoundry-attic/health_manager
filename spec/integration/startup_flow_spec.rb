require 'spec_helper'

describe "Startup flow of Health Manager", :type => :integration do
  let(:bulk_credentials) {
    encode_json({
      :user => "some_user",
      :password => "some_password",
    })
  }

  it "attempts to get bulk api credentials " do
    credentials_requested = false
    with_nats_server do
      NATS.subscribe("cloudcontroller.bulk.credentials.default") do |_,reply|
        NATS.publish(reply, bulk_credentials) {
          credentials_requested = true
          graceful_shutdown(:hm, @hm_pid)
          done_with_nats
        }
      end

      NATS.flush { startup_health_manager }
    end

    expect(credentials_requested).to eq true
  end
end
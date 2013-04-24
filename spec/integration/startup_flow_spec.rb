require 'spec_helper'

describe "Startup flow of Health Manager", :type => :integration do
  let(:bulk_credentials) do
    encode_json(
      :user => "some_user",
      :password => "some_password",
    )
  end

  it "attempts to get bulk api credentials " do
    credentials_requested = false

    with_nats_server do
      NATS.subscribe("cloudcontroller.bulk.credentials.default") do |_,reply|
        NATS.publish(reply, bulk_credentials) do
          credentials_requested = true
          stop_health_manager
          NATS.stop
        end
      end

      NATS.flush { start_health_manager }
    end

    expect(credentials_requested).to eq true
  end
end
require 'spec_helper'

describe "when NATS fails", :type => :integration do
  let(:fake_bulk_api_port) { 30001 }

  before do
    start_nats_server
    start_fake_bulk_api(fake_bulk_api_port)

    start_health_manager({
      "intervals" => {
        "expected_state_update" => 1,
        "expected_state_lost" => 1,
        "droplet_lost" => 2,
        "droplets_analysis" => 1
      },
      "bulk_api" => {
        "host" => "http://127.0.0.1:#{fake_bulk_api_port}"
      }
    })

    sleep 3
    stop_nats_server
    sleep 3
  end

  after do
    stop_health_manager
    stop_fake_bulk_api
    stop_nats_server
  end

  it "does not crash" do
    expect(health_manager_up?).to be_true
  end

  describe "when NATS becomes available again" do
    before do
      start_nats_server
    end

    it "does not suggest that apps be restarted" do
      hm_messages = []

      run_nats_for_time(1.5) do
        NATS.subscribe("cloudcontrollers.hm.requests.default") { |m| hm_messages << m }
      end

      expect(hm_messages).to have(0).messages
    end
  end
end
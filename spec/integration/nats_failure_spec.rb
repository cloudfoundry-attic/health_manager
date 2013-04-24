require 'spec_helper'

describe "when NATS fails", :type => :integration do
  let(:fake_bulk_api_port) { 30001 }
  let(:nats_port) { 4233 }

  before do
    start_nats_server(nats_port)
    start_fake_bulk_api(fake_bulk_api_port, nats_port)

    start_health_manager({
      "mbus" => "nats://nats:nats@127.0.0.1:#{nats_port}",
      "intervals" => {
        "expected_state_update" => 1,
        "expected_state_lost" => 1,
        "droplet_lost" => 2,
        "droplets_analysis" => 1,
        "check_nats_availability" => 1
      },
      "bulk_api" => {
        "host" => "http://127.0.0.1:#{fake_bulk_api_port}"
      }
    })

    sleep 3
    stop_nats_server
    wait_until { !nats_up?(nats_port) }
    sleep 2
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
      start_nats_server(nats_port)
    end

    it "does not suggest that apps be restarted" do
      hm_messages = []

      run_nats_for_time(1, nats_port) do
        NATS.subscribe("cloudcontrollers.hm.requests.default") { |m| hm_messages << m }
      end

      expect(hm_messages).to have(0).messages
    end

    it "resumes its suggestions to restart crashed apps" do
      hm_messages = []

      run_nats_for_time(4, nats_port) do
        EM.add_periodic_timer(1.5) do
          NATS.publish("dea.heartbeat", Yajl::Encoder.encode({
            "dea" => "some-guid",
            "droplets" => [
              {
                "droplet" => "app-id1",
                "index" => 0,
                "instance" => "instance-guid1",
                "state" => "RUNNING",
                "version" => "some-version",
                "cc_partition" => "default"
              },
              {
                "droplet" => "app-id1",
                "index" => 1,
                "instance" => "instance-guid2",
                "state" => "RUNNING",
                "version" => "some-version",
                "cc_partition" => "default"
              },
              {
                "droplet" => "app-id2",
                "index" => 1,
                "instance" => "instance-guid3",
                "state" => "RUNNING",
                "version" => "some-version",
                "cc_partition" => "default"
              },
            ]
          }))
        end

        NATS.subscribe("cloudcontrollers.hm.requests.default") { |m| hm_messages << Yajl::Parser.parse(m) }
      end

      app_ids = hm_messages.map { |msg| msg["droplet"] }
      operations = hm_messages.map { |msg| msg["op"] }
      instance_indices = hm_messages.map { |msg| msg["indices"] }

      expect(operations).to eq(["START", "START"])
      expect(app_ids).to eq(["app-id2", "app-id2"])
      expect(instance_indices).to match_array([[0], [2]])
    end
  end
end
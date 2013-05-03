require 'spec_helper'

describe "when NATS fails", :type => :integration do
  let(:fake_bulk_api_port) { 30001 }
  let(:nats_port) { 4233 }
  let(:lost_droplet_time) { 2 }

  before do
    start_nats_server(nats_port)
    start_fake_bulk_api(fake_bulk_api_port, nats_port)

    start_health_manager(
      "mbus" => "nats://nats:nats@127.0.0.1:#{nats_port}",
      "intervals" => {
        "expected_state_update" => 1,
        "expected_state_lost" => 5,
        "droplet_lost" => lost_droplet_time,
        "droplets_analysis" => 1,
        "check_nats_availability" => 1
      },
      "bulk_api" => {
        "host" => "http://127.0.0.1:#{fake_bulk_api_port}"
      }
    )

    sleep 1
    stop_nats_server
    wait_until { !nats_up?(nats_port) }
    sleep lost_droplet_time + 1
  end

  after do
    stop_health_manager
    stop_fake_bulk_api
    stop_nats_server
  end

  def send_dea_heartbeat(droplets)
    droplets_msg = []
    droplets.each do |name, states|
      states.each do |index|
        droplets_msg << {
          "droplet" => name,
          "index" => index,
          "instance" => "instance-guid#{index}",
          "state" => "RUNNING",
          "version" => "some-version-#{name}",
          "cc_partition" => "default"
        }
      end
    end
    NATS.publish("dea.heartbeat", Yajl::Encoder.encode({
      "dea" => "some-guid",
      "droplets" => droplets_msg
    }))
  end

  it "does not crash even after a long delay but is in a degraded state" do
    sleep (NATS::MAX_RECONNECT_ATTEMPTS * NATS::RECONNECT_TIME_WAIT) + 2
    expect(health_manager_up?).to be_true
  end

  describe "when NATS becomes available again" do
    before do
      start_nats_server(nats_port)
    end

    it "does not suggest that apps be restarted" do
      hm_messages = []

      run_nats_for_time(5, nats_port) do
        NATS.subscribe("cloudcontrollers.hm.requests.default") do |m|
          hm_messages << m
        end

        EM.add_periodic_timer(1.5) do
          send_dea_heartbeat(
            {
              "app-id1" => [0, 1],
              "app-id2" => [0, 1, 2],
            }
          )
        end
      end

      expect(hm_messages).to have(0).messages
    end

    it "resumes its suggestions to restart crashed apps" do
      hm_messages = []

      run_nats_for_time(3, nats_port) do
        EM.add_periodic_timer(2) do
          send_dea_heartbeat(
            {
              "app-id1" => [0, 1],
              "app-id2" => [1],
            }
          )
        end

        NATS.subscribe("cloudcontrollers.hm.requests.default") do |m|
          hm_messages << Yajl::Parser.parse(m)
        end
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
require 'spec_helper'
require 'cf_message_bus/mock_message_bus'

describe HealthManager::Reporter do
  let(:config) do
    {
      'logging' => {
        'file' => "/dev/null"
      }
    }
  end
  let(:manager) do
    m = HealthManager::Manager.new(config)
    m.setup_components(message_bus)
    m
  end
  let(:message_bus) { CfMessageBus::MockMessageBus.new }

  let(:reporter) { manager.reporter }

  it "subscribe to topics" do
    message_bus.should_receive(:subscribe).with('healthmanager.status')
    message_bus.should_receive(:subscribe).with('healthmanager.health')
    message_bus.should_receive(:subscribe).with('healthmanager.droplet')
    reporter.prepare
  end

  let(:reply_to) { '_INBOX.1234' }
  let(:droplet) { HealthManager::Droplet.new('some_droplet_id') }
  let(:message) { { :droplets => [{ :droplet => droplet.id}]} }

  it "should publish a response to droplet request" do
    reporter.droplet_registry.stub(:include? => true, :[] => droplet)
    message_bus.should_receive(:publish).with(reply_to, droplet)
    reporter.process_droplet_message(message, reply_to)
  end

  describe "#process_health_message" do
    before do
      @droplet_1 = reporter.droplet_registry.get("droplet_1")
      @droplet_2 = reporter.droplet_registry.get("droplet_2")
      @droplet_1.process_heartbeat(HealthManager::Heartbeat.new({ instance: 'd1_instance_1', state: 'RUNNING', version: "v1", index: 0, state_timestamp: 0 }))
      @droplet_1.process_heartbeat(HealthManager::Heartbeat.new({ instance: 'd1_instance_2', state: 'RUNNING', version: "v1", index: 1, state_timestamp: 0 }))
      @droplet_1.num_instances = 2

      @droplet_2.process_heartbeat(HealthManager::Heartbeat.new({ instance: 'd2_instance_1', state: 'RUNNING', version: "v3", index: 0, state_timestamp: 0 }))
      @droplet_2.process_heartbeat(HealthManager::Heartbeat.new({ instance: 'd2_instance_2', state: 'STOPPED', version: "v3", index: 1, state_timestamp: 0 }))
      @droplet_2.num_instances = 2

      @responses = []
      message_bus.stub(:publish) do |the_reply_to, response|
        expect(the_reply_to).to eql(reply_to)
        @responses << response
      end

      reporter.process_health_message({droplets: [{droplet: "droplet_1", version:"v1"}, {droplet:"droplet_2", version:"v3"}, {droplet:"droplet_3", version:"v1"}]}, reply_to)
    end

    it "should return a response for each droplet that it knows about" do
      expect(@responses.count).to eql(2)
      expect(@responses[0]).to eql({
                                      droplet: "droplet_1",
                                      version: "v1",
                                      healthy: 2
                                   })
      expect(@responses[1]).to eql({
                                     droplet: "droplet_2",
                                     version: "v3",
                                     healthy: 1
                                   })
    end

    it "should not create extra droplets in the registry" do
      expect(reporter.droplet_registry).not_to have_key("droplet_3")
    end
  end
end
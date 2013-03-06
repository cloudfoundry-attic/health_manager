require 'spec_helper'

describe HealthManager do
  describe HealthManager::Reporter do

    let(:manager) do
      m = HealthManager::Manager.new
      m.varz.prepare
      m
    end

    let(:publisher) { manager.publisher }
    let(:provider) { manager.known_state_provider }

    subject { manager.reporter }

    it "subscribe to topics" do
      NATS.should_receive(:subscribe).with('healthmanager.status')
      NATS.should_receive(:subscribe).with('healthmanager.health')
      NATS.should_receive(:subscribe).with('healthmanager.droplet')
      subject.prepare
    end


    let(:reply_to) { '_INBOX.1234' }
    let(:app_state) { HealthManager::AppState.new('some_droplet_id') }

    let(:message) { {:droplets => [{:droplet => app_state.id}]} }
    let(:message_str) { manager.encode_json(message) }

    it "should publish a response to droplet request" do

      provider.stub(:has_droplet? => true)
      provider.stub(:get_droplet => app_state)
      publisher.should_receive(:publish)
        .with(reply_to, manager.encode_json(app_state))
      subject.process_droplet_message(message_str, reply_to)
    end
  end
end

require 'spec_helper'

describe HealthManager::Reporter do
  let(:config) do
    {
      'logging' => {
        'file' => "/dev/null"
      }
    }
  end
  let(:manager) { HealthManager::Manager.new(config) }

  let(:publisher) { manager.publisher }
  let(:provider) { subject.droplet_registry }

  subject { manager.reporter }

  it "subscribe to topics" do
    NATS.should_receive(:subscribe).with('healthmanager.status')
    NATS.should_receive(:subscribe).with('healthmanager.health')
    NATS.should_receive(:subscribe).with('healthmanager.droplet')
    subject.prepare
  end


  let(:reply_to) { '_INBOX.1234' }
  let(:droplet) { HealthManager::Droplet.new('some_droplet_id') }

  let(:message) { {:droplets => [{:droplet => droplet.id}]} }
  let(:message_str) { manager.encode_json(message) }

  it "should publish a response to droplet request" do
    provider.stub(:include? => true)
    provider.stub(:[] => droplet)
    publisher.should_receive(:publish).with(reply_to, manager.encode_json(droplet))
    subject.process_droplet_message(message_str, reply_to)
  end
end
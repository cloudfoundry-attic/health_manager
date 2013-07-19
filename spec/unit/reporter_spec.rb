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

  let(:provider) { subject.droplet_registry }

  subject { manager.reporter }

  it "subscribe to topics" do
    message_bus.should_receive(:subscribe).with('healthmanager.status')
    message_bus.should_receive(:subscribe).with('healthmanager.health')
    message_bus.should_receive(:subscribe).with('healthmanager.droplet')
    subject.prepare
  end


  let(:reply_to) { '_INBOX.1234' }
  let(:droplet) { HealthManager::Droplet.new('some_droplet_id') }

  let(:message) { {'droplets' => [{'droplet' => droplet.id}]} }

  it "should publish a response to droplet request" do
    provider.stub(:include? => true)
    provider.stub(:[] => droplet)
    message_bus.should_receive(:publish).with(reply_to, droplet)
    subject.process_droplet_message(message, reply_to)
  end
end
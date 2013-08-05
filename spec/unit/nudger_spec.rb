require 'spec_helper'
require 'cf_message_bus/mock_message_bus'

module HealthManager
  describe Nudger do
    let(:config) do
      {
        'logging' => {
          'file' => "/dev/null"
        }
      }
    end

    let(:manager) do
      m = Manager.new(config)
      m.setup_components(message_bus)
      m
    end
    let(:message_bus) { CfMessageBus::MockMessageBus.new }
    let(:nudger) { manager.nudger }
    let(:varz) { manager.varz }

    it 'should be able to start app instance' do
      message_bus.should_receive(:publish).with("health.start", hash_including(indices: [0])).once
      nudger.start_instance(Droplet.new(1), 0, 0)
      nudger.deque_batch_of_requests
      expect(varz[:health_start_messages_sent]).to eql(1)
    end

    it "includes the running count in start requests" do
      droplet = Droplet.new(1)
      droplet.process_heartbeat(Heartbeat.new(
        :instance => "some-instances",
        :timestamp => 0,
        :state => RUNNING,
        :index => 0,
        :version => "some-version",
        :state_timestamp => 0
      ))
      droplet.process_heartbeat(Heartbeat.new(
        :instance => "some-instances",
        :timestamp => 0,
        :state => DOWN,
        :index => 1,
        :version => "some-version",
        :state_timestamp => 0
      ))

      message_bus.should_receive(:publish).with("health.start", hash_including(running: {'some-version' => 1})).once

      nudger.start_instance(droplet, 0, 0)
      nudger.deque_batch_of_requests
    end

    it 'should be able to stop app instance' do
      message_bus.should_receive(:publish).with("health.stop", hash_including(instances: 0)).once
      nudger.stop_instance(Droplet.new(1), 0, 0)
      nudger.deque_batch_of_requests
      expect(varz[:health_stop_messages_sent]).to eql(1)
    end

    it "includes the running count in stop requests" do
      droplet = Droplet.new(1)
      droplet.process_heartbeat(Heartbeat.new(
        :instance => "some-instances",
        :timestamp => 0,
        :state => RUNNING,
        :index => 0,
        :version => "some-version",
        :state_timestamp => 0
      ))
      droplet.process_heartbeat(Heartbeat.new(
        :instance => "some-instances",
        :timestamp => 0,
        :state => DOWN,
        :index => 1,
        :version => "some-version",
        :state_timestamp => 0
      ))

      message_bus.should_receive(:publish).with("health.stop", hash_including(running: {'some-version' => 1})).once

      nudger.stop_instance(droplet, 0, 0)
      nudger.deque_batch_of_requests
    end

    it "includes the version in stop requests" do
      droplet = Droplet.new(1)
      droplet.set_desired_state(
        "state" => "STOPPED",
        "instances" => 2,
        "version" => "some-version",
        "package_state" => "whatevs",
        "updated_at" => "2013-06-24"
      )

      message_bus.should_receive(:publish).with("health.stop", hash_including(version: 'some-version')).once

      nudger.stop_instance(droplet, 0, 0)
      nudger.deque_batch_of_requests
    end

    context(:queuing) do
      let(:message1) do
        {
          :true_key => 'some_key',
          :last_updated => 123,
        }
      end

      let(:message2) do
        {
          :true_key => 'some_key',
          :last_updated => 234,
        }
      end

      let(:message3) do
        {
          :true_key => 'some_other_key',
          :last_updated => 123,
        }
      end

      it 'should not queue messages with keys already in the queue, regardless of :last_updated value' do
        10.times do # can do as many dupes as we want
          nudger.queue("fizz", message1)
          nudger.queue("fizz", message2)
        end

        message_bus.should_receive(:publish).
          exactly(:once).
          with("health.fizz", message1)

        nudger.deque_batch_of_requests
      end

      it 'should queue messages in accordance with message key, not by :last_updated value' do
        10.times do
          nudger.queue("foo", message1)
          nudger.queue("foo", message3)
        end

        message_bus.should_receive(:publish).exactly(2).times
        nudger.deque_batch_of_requests
      end
    end
  end
end

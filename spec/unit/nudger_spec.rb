require 'spec_helper'

module HealthManager
  describe Nudger do
    let(:config) do
      {
        'logging' => {
          'file' => "/dev/null"
        }
      }
    end
    let(:manager) { Manager.new(config) }

    let(:nudger) { manager.nudger }
    let(:publisher) { manager.publisher }

    it 'should be able to start app instance' do
      publisher.should_receive(:publish).with('cloudcontrollers.hm.requests.default', match(/"op":"START"/)).once
      nudger.start_instance(Droplet.new(1), 0, 0)
      nudger.deque_batch_of_requests
    end

    it 'should be able to stop app instance' do
      publisher.should_receive(:publish).with('cloudcontrollers.hm.requests.default', match(/"op":"STOP"/)).once
      nudger.stop_instance(Droplet.new(1), 0, 0)
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
          nudger.queue(message1)
          nudger.queue(message2)
        end

        publisher.should_receive(:publish).exactly(:once)
          .with("cloudcontrollers.hm.requests.default", manager.encode_json(message1))
        nudger.deque_batch_of_requests
      end

      it 'should queue messages in accordance with message key, not by :last_updated value' do
        10.times do
          nudger.queue(message1)
          nudger.queue(message3)
        end

        publisher.should_receive(:publish).exactly(2).times
        nudger.deque_batch_of_requests
      end
    end
  end
end

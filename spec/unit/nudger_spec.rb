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
      publisher.should_receive(:publish).with("health.start", match(/"indices":\[0\]/)).once
      nudger.start_instance(Droplet.new(1), 0, 0)
      nudger.deque_batch_of_requests
    end

    it "includes the running count in start requests" do
      droplet = Droplet.new(1)

      droplet.versions["some-version"] = {
        "instances" => {
          0 => { "instance" => "some-instances",
            "timestamp" => 0,
            "state" => RUNNING
          },
          1 => { "instance" => "some-instances",
            "timestamp" => 0,
            "state" => DOWN
          }
        }
      }

      publisher.should_receive(:publish).with("health.start", match(/"running":\{"some-version":1\}/)).once

      nudger.start_instance(droplet, 0, 0)
      nudger.deque_batch_of_requests
    end

    it 'should be able to stop app instance' do
      publisher.should_receive(:publish).with("health.stop", match(/"instances":0/)).once
      nudger.stop_instance(Droplet.new(1), 0, 0)
      nudger.deque_batch_of_requests
    end

    it "includes the running count in stop requests" do
      droplet = Droplet.new(1)

      droplet.versions["some-version"] = {
        "instances" => {
          0 => { "instance" => "some-instances",
            "timestamp" => 0,
            "state" => RUNNING
          },
          1 => { "instance" => "some-instances",
            "timestamp" => 0,
            "state" => DOWN
          }
        }
      }

      publisher.should_receive(:publish).with("health.stop", match(/"running":\{"some-version":1\}/)).once

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

      publisher.should_receive(:publish).with("health.stop", match(/"version":"some-version"/)).once

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

        publisher.should_receive(:publish).
          exactly(:once).
          with("health.fizz", manager.encode_json(message1))

        nudger.deque_batch_of_requests
      end

      it 'should queue messages in accordance with message key, not by :last_updated value' do
        10.times do
          nudger.queue("foo", message1)
          nudger.queue("foo", message3)
        end

        publisher.should_receive(:publish).exactly(2).times
        nudger.deque_batch_of_requests
      end
    end
  end
end

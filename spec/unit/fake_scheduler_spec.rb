require 'spec_helper'
require 'cf_message_bus/mock_message_bus'

describe HealthManager::FakeScheduler do
  before do
    config = {intervals: {an_interval: 7, another_interval: 5}}
    HealthManager::Config.load(config)

    @message_bus = CfMessageBus::MockMessageBus.new
    @scheduler = HealthManager::FakeScheduler.new(@message_bus)
  end

  describe "upon receiving healthmanager.advance_time" do
    it "should advance time" do
      calls = []
      @scheduler.at_interval(:an_interval) do ||
        calls << true
      end

      @message_bus.publish("healthmanager.advance_time", {seconds: 15})

      calls.length.should == 2
    end
  end

  describe "at_interval" do
    it "schedule one periodic event" do
      calls = []
      @scheduler.at_interval(:an_interval) do ||
        calls << true
      end

      @scheduler.advance_time(6)
      calls.length.should == 0

      @scheduler.advance_time(1)
      calls.should == [true]

      @scheduler.advance_time(6)
      calls.should == [true]

      @scheduler.advance_time(1)
      calls.should == [true, true]

      @scheduler.advance_time(14)
      calls.should == [true, true, true, true]
    end

    it "schedules multiple periodic events" do
      calls_a = []
      calls_b = []

      @scheduler.at_interval(:an_interval) do ||
        calls_a << true
      end

      @scheduler.at_interval(:another_interval) do ||
        calls_b << true
      end

      @scheduler.advance_time(4)
      calls_a.should == []
      calls_b.should == []

      @scheduler.advance_time(1)
      calls_a.should == []
      calls_b.should == [true]

      @scheduler.advance_time(2)
      calls_a.should == [true]
      calls_b.should == [true]

      @scheduler.advance_time(17)
      calls_a.should == [true, true, true]
      calls_b.should == [true, true, true, true]
    end
  end

  describe "immediately" do
    it "calls the passed in block immediately" do
      calls = []
      @scheduler.immediately do ||
        calls << true
      end
      calls.should == [true]
    end
  end

  describe "after" do
    it "should run the block once after the interval elapses" do
      calls = []

      @scheduler.after(2) do ||
        calls << true
      end

      @scheduler.advance_time(1)
      calls.should == []

      @scheduler.advance_time(1)
      calls.should == [true]

      @scheduler.advance_time(17)
      calls.should == [true]
    end

    context "when cancelling the receipt" do
      it "should not run the block" do
        calls = []

        r = @scheduler.after(2) do ||
          calls << true
        end
        @scheduler.cancel(r)

        @scheduler.advance_time(2)
        calls.should == []
      end
    end

    context "cancelling the receipt after the block has run" do
      it "should be ok" do
        calls = []

        r = @scheduler.after(2) do ||
          calls << true
        end
        @scheduler.advance_time(2)
        @scheduler.cancel(r)

        calls.should == [true]
      end
    end
  end
end
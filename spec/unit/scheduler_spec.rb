require 'spec_helper'

describe HealthManager::Scheduler do
  describe '#interval' do
    it 'should return configured interval values' do
      s1 = HealthManager::Scheduler.new(:intervals => {:droplets_analysis => 7})
      s2 = HealthManager::Scheduler.new('intervals' => {'droplets_analysis' => 6})

      s1.interval(:droplets_analysis).should == 7
      s1.interval('droplets_analysis').should == 7
      s2.interval(:droplets_analysis).should == 6
      s2.interval('droplets_analysis').should == 6
    end

    it 'should return default interval values' do
      subject.interval(:analysis_delay).should == HealthManager::DEFAULTS[:analysis_delay]
      subject.interval('analysis_delay').should == HealthManager::DEFAULTS[:analysis_delay]
    end

    it 'should raise ArgumentError for invalid intervals' do
      lambda { subject.interval(:bogus) }.should raise_error(ArgumentError, /undefined parameter/)
    end
  end

  it 'should be able to schedule own termination' do
    subject.schedule :timer => 1 do
      subject.stop
    end
    start_at = HealthManager::Manager.now
    subject.start
    stop_at = HealthManager::Manager.now
    stop_at.should > start_at #at least a second should have elapsed
  end

  it 'should be able to execute immediately' do
    done = false
    subject.immediately do
      done = true
    end
    subject.immediately do
      subject.stop
    end
    subject.start
    done.should be_true
  end

  it 'should be able to schedule periodic' do
    count = 0
    subject.schedule :timer => 1.1 do
      subject.stop
    end

    subject.schedule :periodic => 0.3 do
      count += 1
    end

    subject.start
    count.should == 3
  end

  it 'should be able to schedule multiple blocks' do
    #this shows running the scheduler within explicit EM.run
    EM.run do
      @counter = Hash.new(0)
      subject.immediately do
        @counter[:immediate] += 1
      end
      subject.every 0.3 do
        @counter[:periodic] += 1
      end
      subject.every 0.7 do
        @counter[:timer] += 1
      end
      #set up expectations for two points in time:
      EM.add_timer(0.5) do
        @counter[:immediate].should == 1
        @counter[:periodic].should == 1
        @counter[:timer].should == 0
      end
      EM.add_timer(1.1) do
        @counter[:immediate].should == 1
        @counter[:periodic].should == 3
        @counter[:timer].should == 1
        EM.stop
      end
      subject.run
    end
  end

  it 'should allow cancelling scheduled blocks' do
    flag = false
    cancelled_flag = false

    cancelled_timer1 = subject.schedule(:timer => 0.1) do
      cancelled_flag = true
    end

    cancelled_timer2 = subject.after 0.3 do
      cancelled_flag = true
    end

    subject.after 0.2 do
      flag = true
      subject.cancel(cancelled_timer2)
    end

    subject.after 1 do
      subject.stop
    end

    subject.cancel(cancelled_timer1)

    subject.start

    cancelled_flag.should be_false
    flag.should be_true
  end
end
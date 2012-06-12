require 'spec_helper.rb'

describe HealthManager do

  Manager = HealthManager::Manager
  Harmonizer = HealthManager::Harmonizer
  KnownStateProvider = HealthManager::KnownStateProvider
  ExpectedStateProvider = HealthManager::ExpectedStateProvider
  Reporter = HealthManager::Reporter
  Scheduler = HealthManager::Scheduler
  Nudger = HealthManager::Nudger
  Varz = HealthManager::Varz

  before(:all) do
    EM.error_handler do |e|
      fail "EM error: #{e.message}"
    end
  end

  before(:each) do
    @config = {:intervals =>
      {
        :expected_state_update => 1.5,
      }
    }
    @m = Manager.new(@config)
    @m.varz.prepare
  end

  describe Manager do
    it 'should have all componets registered and available' do

      @m.harmonizer.should be_a_kind_of Harmonizer

      # chaining components should also work.
      # thus ensuring all components available from all components
      @m.harmonizer.varz.should be_a_kind_of Varz
      @m.varz.reporter.should be_a_kind_of Reporter
      @m.reporter.known_state_provider.should be_a_kind_of KnownStateProvider
      @m.known_state_provider.expected_state_provider.should be_a_kind_of ExpectedStateProvider
      @m.expected_state_provider.nudger.should be_a_kind_of Nudger
      @m.nudger.scheduler.should be_a_kind_of Scheduler
    end
  end

  describe Harmonizer do
    it 'should be able to describe a policy of bringing a known state to expected state'
  end
end

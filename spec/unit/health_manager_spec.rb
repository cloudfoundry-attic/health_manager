require 'spec_helper'

describe HealthManager do

  before(:all) do
    EM.error_handler do |e|
      fail "EM error: #{e.message}\n#{e.backtrace}"
    end
  end

  before(:each) do
    @config = {
      :shadow_mode => 'enable',
      :intervals =>
      {
        :expected_state_update => 1.5,
      }
    }
    @m = Manager.new(@config)
    @m.varz.prepare
  end

  describe "Manager" do
    it 'should not publish to NATS when registering as vcap_component in shadow mode' do
      in_em do
        NATS.should_receive(:subscribe).once
        NATS.should_not_receive(:publish)
        @m.register_as_vcap_component
      end
    end

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

  describe "Harmonizer" do
    it 'should be able to describe a policy of bringing a known state to expected state'
  end
end

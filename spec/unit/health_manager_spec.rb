require 'spec_helper'
require 'cf_message_bus/mock_message_bus'

describe HealthManager do

  let(:config) do
    {
      'intervals' => {
        'desired_state_update' => 1.5,
      },
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

  before do
    EM.error_handler do |e|
      fail "EM error: #{e.message}\n#{e.backtrace}"
    end
  end

  after do
    EM.error_handler # remove our handler
  end

  describe "Manager" do
    it 'should construct appropriate dependencies' do
      manager.harmonizer.should be_a_kind_of HealthManager::Harmonizer
      manager.harmonizer.varz.should be_a_kind_of HealthManager::Varz
      manager.harmonizer.desired_state.should be_a_kind_of HealthManager::DesiredState
      manager.harmonizer.nudger.should be_a_kind_of HealthManager::Nudger
      manager.actual_state.harmonizer.should eq manager.harmonizer
    end

    it "registers a log counter with the component" do
      log_counter = Steno::Sink::Counter.new
      Steno::Sink::Counter.should_receive(:new).once.and_return(log_counter)

      Steno.should_receive(:init) do |steno_config|
        expect(steno_config.sinks).to include log_counter
      end

      VCAP::Component.should_receive(:register).with(hash_including(:log_counter => log_counter))
      manager.register_as_vcap_component(message_bus)
    end
  end

  describe "Garbage collection of droplets" do
    GRACE_PERIOD = 60
    let(:config) do
      {
        :intervals => {
          :droplet_gc_grace_period => GRACE_PERIOD
        },
        'logging' => {
          'file' => "/dev/null"
        }
      }
    end

    before do
      manager #load up the config!
      app,@desired = make_app
      @hb = make_heartbeat_message([app])

      @h = manager.harmonizer

      @actual_state = manager.actual_state
      manager.droplet_registry.size.should == 0

      HealthManager::Config.load(config)
    end

    it 'should not GC when a recent h/b arrives' do
      @actual_state.send(:process_heartbeat, @hb)
      manager.droplet_registry.size.should == 1
      droplet = manager.droplet_registry.values.first

      droplet.should_not be_ripe_for_gc
      @h.gc_droplets

      manager.droplet_registry.size.should == 1

      Timecop.travel(Time.now + GRACE_PERIOD + 10)

      droplet.should be_ripe_for_gc

      @h.gc_droplets
      manager.droplet_registry.size.should == 0
    end

    it 'should not GC after desired state is set' do
      @actual_state.send(:process_heartbeat, @hb)
      droplet = manager.droplet_registry.values.first

      Timecop.travel(Time.now + GRACE_PERIOD + 10)

      droplet.should be_ripe_for_gc

      droplet.set_desired_state(@desired)
      droplet.should_not be_ripe_for_gc
    end
  end
end

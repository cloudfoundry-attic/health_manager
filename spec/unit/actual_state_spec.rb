require 'spec_helper'
require 'cf_message_bus/mock_message_bus'

describe HealthManager::ActualState do
  let(:droplet_registry) { HealthManager::DropletRegistry.new }
  let(:harmonizer) { double }
  let(:flapping_death) { 3 }
  let(:config) { { :intervals => { :flapping_death => flapping_death } } }
  let(:message_bus) { CfMessageBus::MockMessageBus.new }

  before do
    HealthManager::Config.load(config)
    @actual_state = HealthManager::ActualState.new(HealthManager::Varz.new, droplet_registry, message_bus)
    @actual_state.harmonizer = harmonizer
    @actual_state.start
  end

  context 'Droplet updating' do
    before(:each) do
      app, desired = make_app
      @droplet = droplet_registry.get(app.id)
      @droplet.set_desired_state(desired)
      instance = @droplet.get_instance(0)
      instance.should be_down
      instance.should_not have_recent_heartbeat
      harmonizer.stub(:on_extra_instances)
    end

    def make_and_send_heartbeat
      hb = make_heartbeat_message([@droplet])
      message_bus.publish('dea.heartbeat', hb)
    end

    def make_and_send_exited_message(reason)
      msg = make_crash_message(@droplet, :reason => reason)
      message_bus.publish('droplet.exited', msg)
    end

    def make_and_send_update_message(options = {})
      msg = make_update_message(@droplet, options)
      message_bus.publish('droplet.updated', msg)
    end

    def check_instance_state(state='RUNNING')
      instance = @droplet.get_instance(0)
      instance.state.should == state
      instance.should have_recent_heartbeat
    end

    it 'should forward heartbeats' do
      harmonizer.should_receive(:on_extra_instances).with(@droplet, {})
      make_and_send_heartbeat
      check_instance_state
    end

    it "processes droplet update" do
      harmonizer.should_receive(:on_droplet_updated).with(@droplet, hash_including(:droplet => @droplet.id))
      @droplet.should_receive(:reset_missing_indices)
      make_and_send_update_message
    end

    it 'should mark instances that crashed as CRASHED' do
      harmonizer.should_receive(:on_exit_crashed).with(@droplet, hash_including(:reason => "CRASHED"))
      make_and_send_heartbeat
      check_instance_state('RUNNING')

      make_and_send_exited_message('CRASHED')
      check_instance_state('CRASHED')

      make_and_send_heartbeat
      check_instance_state('RUNNING')
    end

    it 'should mark instances that were stopped or evacuated as DOWN' do
      harmonizer.stub(:on_exit_dea => nil, :on_exit_stopped => nil)
      make_and_send_heartbeat
      check_instance_state('RUNNING')

      %w[STOPPED DEA_SHUTDOWN DEA_EVACUATION].each do |reason|
        make_and_send_exited_message(reason)
        check_instance_state('DOWN')
        make_and_send_heartbeat
        check_instance_state('RUNNING')
      end
    end

    it "calls harmonizer.on_exit_dea when the DEA shuts down" do
      harmonizer.should_receive(:on_exit_dea).with(@droplet, hash_including(:reason => "DEA_SHUTDOWN"))
      make_and_send_heartbeat
      make_and_send_exited_message("DEA_SHUTDOWN")
    end

    it "calls harmonizer.on_exit_dea when the DEA evacuates" do
      harmonizer.should_receive(:on_exit_dea).with(@droplet, hash_including(:reason => "DEA_EVACUATION"))
      make_and_send_heartbeat
      make_and_send_exited_message("DEA_EVACUATION")
    end

    it "calls harmonizer.on_exit_stopped when it receives the message dea.stop" do
      harmonizer.should_receive(:on_exit_stopped).with(hash_including(:reason => "STOPPED"))
      make_and_send_heartbeat
      make_and_send_exited_message("STOPPED")
    end
  end

  describe "available?" do
    subject { @actual_state.available? }

    context "when not connected to message bus" do
      before { message_bus.stub(:connected?) { false } }
      it { should be_false }
    end

    context "when connected to message bus" do
      before { message_bus.stub(:connected?) { true } }
      it { should be_true }
    end
  end
end

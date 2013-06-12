require 'spec_helper'

describe HealthManager::ActualState do
  let(:droplet_registry) { HealthManager::DropletRegistry.new }
  let(:harmonizer) { double }
  before do
    HealthManager::Droplet.flapping_death = 3
    @actual_state = HealthManager::ActualState.new({}, HealthManager::Varz.new, droplet_registry)
    @actual_state.harmonizer = harmonizer
  end

  describe "check_availability" do
    context "when not connected to nats" do
      before do
        NATS.stub(:subscribe)
        NATS.stub(:connected?).and_return(false)
      end

      it "does not try to subscribe" do
        NATS.should_not_receive(:subscribe)
        @actual_state.start
      end

      context "when NATS comes back up" do
        before do
          @actual_state.start
          NATS.stub(:connected?).and_return(true)
        end

        it "logs that it is subscribing" do
          @actual_state.logger.should_receive(:info).with(/subscribing/).exactly(3).times
          @actual_state.start
        end

        it "re-subscribes to heartbeat, droplet.exited/updated messages" do
          NATS.should_receive(:subscribe).with('dea.heartbeat')
          NATS.should_receive(:subscribe).with('droplet.exited')
          NATS.should_receive(:subscribe).with('droplet.updated')
          @actual_state.start
        end

        context "when NATS goes down again" do
          before do
            @actual_state.start
            NATS.stub(:connected?).and_return(false)
          end

          it "logs that nats went down" do
            @actual_state.logger.should_receive(:info).with(/NATS/)
            @actual_state.start
          end
        end
      end
    end
  end

  context 'Droplet updating' do
    before(:each) do
      app, desired = make_app
      @droplet = droplet_registry.get(app.id)
      @droplet.set_desired_state(desired)
      instance = @droplet.get_instance(@droplet.live_version, 0)
      instance['state'].should == 'DOWN'
      instance['last_heartbeat'].should be_nil
      harmonizer.stub(:on_extra_instances)
    end

    def make_and_send_heartbeat
      hb = make_heartbeat([@droplet])
      @actual_state.send(:process_heartbeat, encode_json(hb))
    end

    def make_and_send_exited_message(reason)
      msg = make_exited_message(@droplet, 'reason'=>reason)
      @actual_state.send(:process_droplet_exited, encode_json(msg))
    end

    def make_and_send_update_message(options = {})
      msg = make_update_message(@droplet, options)
      @actual_state.send(:process_droplet_updated, encode_json(msg))
    end

    def check_instance_state(state='RUNNING')
      instance = @droplet.get_instance(@droplet.live_version, 0)
      instance['state'].should == state
      instance['last_heartbeat'].should_not be_nil
    end

    it 'should forward heartbeats' do
      harmonizer.should_receive(:on_extra_instances).with(@droplet, [])
      make_and_send_heartbeat
      check_instance_state
    end

    it "processes droplet update" do
      harmonizer.should_receive(:on_droplet_updated).with(@droplet, hash_including("droplet" => @droplet.id))
      @droplet.should_receive(:reset_missing_indices)
      make_and_send_update_message
    end

    it "does not update droplet partition does not match" do
      harmonizer.should_not_receive(:on_droplet_updated)
      @droplet.should_not_receive(:reset_missing_indices)
      make_and_send_update_message(:cc_partition => "OTHER")
    end

    it 'should mark instances that crashed as CRASHED' do
      harmonizer.should_receive(:on_exit_crashed).with(@droplet, hash_including("reason" => "CRASHED"))
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
      harmonizer.should_receive(:on_exit_dea).with(@droplet, hash_including("reason" => "DEA_SHUTDOWN"))
      make_and_send_heartbeat
      make_and_send_exited_message("DEA_SHUTDOWN")
    end

    it "calls harmonizer.on_exit_dea when the DEA evacuates" do
      harmonizer.should_receive(:on_exit_dea).with(@droplet, hash_including("reason" => "DEA_EVACUATION"))
      make_and_send_heartbeat
      make_and_send_exited_message("DEA_EVACUATION")
    end

    it "calls harmonizer.on_exit_stopped when it receives the message dea.stop" do
      harmonizer.should_receive(:on_exit_stopped).with(hash_including("reason" => "STOPPED"))
      make_and_send_heartbeat
      make_and_send_exited_message("STOPPED")
    end
  end

  describe "available?" do
    subject { @actual_state.available? }

    context "when connecting to NATS fails" do
      before { NATS.stub(:connected?) { false } }
      it { should be_false }
    end

    context "when connecting to nats succeeds" do
      before { NATS.stub(:connected?) { true } }
      it { should be_true }
    end
  end
end

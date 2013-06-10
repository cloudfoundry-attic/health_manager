require 'spec_helper'

describe HealthManager::ActualState do
  before do
    HealthManager::AppState.flapping_death = 3
    @nb = HealthManager::ActualState.new({}, HealthManager::Varz.new)
  end

  after do
    HealthManager::AppState.remove_all_listeners
  end

  describe "check_availability" do
    context "when not connected to nats" do
      before do
        NATS.stub(:subscribe)
        NATS.stub(:connected?).and_return(false)
      end

      it "does not try to subscribe" do
        NATS.should_not_receive(:subscribe)
        @nb.check_availability
      end

      context "when NATS comes back up" do
        before do
          @nb.check_availability
          NATS.stub(:connected?).and_return(true)
        end

        it "logs that it is subscribing" do
          @nb.logger.should_receive(:info).with(/subscribing/).exactly(3).times
          @nb.check_availability
        end

        it "re-subscribes to heartbeat, droplet.exited/updated messages" do
          NATS.should_receive(:subscribe).with('dea.heartbeat')
          NATS.should_receive(:subscribe).with('droplet.exited')
          NATS.should_receive(:subscribe).with('droplet.updated')
          @nb.check_availability
        end

        context "when NATS goes down again" do
          before do
            @nb.check_availability
            NATS.stub(:connected?).and_return(false)
          end

          it "logs that nats went down" do
            @nb.logger.should_receive(:info).with(/NATS/)
            @nb.check_availability
          end
        end
      end
    end
  end

  context 'AppState updating' do
    before(:each) do
      app, desired = make_app
      @app = @nb.get_droplet(app.id)
      @app.set_desired_state(desired)
      instance = @app.get_instance(@app.live_version, 0)
      instance['state'].should == 'DOWN'
      instance['last_heartbeat'].should be_nil
    end

    def make_and_send_heartbeat
      hb = make_heartbeat([@app])
      @nb.process_heartbeat(encode_json(hb))
    end

    def make_and_send_exited_message(reason)
      msg = make_exited_message(@app, {'reason'=>reason})
      @nb.process_droplet_exited(encode_json(msg))
    end

    def check_instance_state(state='RUNNING')
      instance = @app.get_instance(@app.live_version, 0)
      instance['state'].should == state
      instance['last_heartbeat'].should_not be_nil
    end

    it 'should forward heartbeats' do
      make_and_send_heartbeat
      check_instance_state
    end

    it 'should mark instances that crashed as CRASHED' do
      make_and_send_heartbeat
      check_instance_state('RUNNING')

      make_and_send_exited_message('CRASHED')
      check_instance_state('CRASHED')

      make_and_send_heartbeat
      check_instance_state('RUNNING')
    end

    it 'should mark instances that were stopped or evacuated as DOWN' do
      make_and_send_heartbeat
      check_instance_state('RUNNING')

      ['STOPPED','DEA_SHUTDOWN','DEA_EVACUATION'].each do |reason|
        make_and_send_exited_message(reason)
        check_instance_state('DOWN')
        make_and_send_heartbeat
        check_instance_state('RUNNING')
      end
    end
  end

  describe "available?" do
    subject { @nb.available? }

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

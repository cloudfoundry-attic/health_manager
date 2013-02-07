require 'spec_helper'

describe HealthManager do

  before(:each) do
    HealthManager::AppState.flapping_death = 3
  end

  after(:each) do
    HealthManager::AppState.remove_all_listeners
  end

  describe "AppStateProvider" do
    describe "NatsBasedKnownStateProvider" do

      before(:each) do
        @nb = HealthManager::NatsBasedKnownStateProvider.new(build_valid_config)
      end

      it 'should subscribe to heartbeat, droplet.exited/updated messages' do
        NATS.should_receive(:subscribe).with('dea.heartbeat')
        NATS.should_receive(:subscribe).with('droplet.exited')
        NATS.should_receive(:subscribe).with('droplet.updated')
        @nb.start
      end

      context 'AppState updating' do

        before(:each) do
          app, expected = make_app
          @app = @nb.get_droplet(app.id)
          @app.set_expected_state(expected)
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
    end
  end

  def build_valid_config(config = {})
    varz = HealthManager::Varz.new(config)
    varz.prepare
    varz.register_hm_component(:varz, varz)
    varz.register_hm_component(:scheduler, @scheduler = HealthManager::Scheduler.new(config))
    config
  end
end

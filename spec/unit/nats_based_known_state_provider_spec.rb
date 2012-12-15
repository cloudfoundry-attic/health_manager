require 'spec_helper'

describe HealthManager do

  include HealthManager::Common

  after :each do
    AppState.remove_all_listeners
  end

  describe "AppStateProvider" do
    describe "NatsBasedKnownStateProvider" do

      before(:each) do
        @nb = NatsBasedKnownStateProvider.new(build_valid_config)
      end

      it 'should subscribe to heartbeat, droplet.exited/updated messages' do
        NATS.should_receive(:subscribe).with('dea.heartbeat')
        NATS.should_receive(:subscribe).with('droplet.exited')
        NATS.should_receive(:subscribe).with('droplet.updated')
        @nb.start
      end

      it 'should forward heartbeats' do
        app, expected = make_app
        app1 = @nb.get_droplet(app.id)
        app1.set_expected_state(expected)

        instance = app1.get_instance(app.live_version, 0)
        instance['state'].should == 'DOWN'
        instance['last_heartbeat'].should be_nil

        hb = make_heartbeat([app])
        @nb.process_heartbeat(encode_json(hb))

        instance = app1.get_instance(app.live_version, 0)
        instance['state'].should == 'RUNNING'
        instance['last_heartbeat'].should_not be_nil
      end
    end
  end

  def build_valid_config(config = {})
    @config = config
    varz = Varz.new(@config)
    varz.prepare
    register_hm_component(:varz, varz)
    register_hm_component(:scheduler, @scheduler = Scheduler.new(@config))
    @config
  end
end

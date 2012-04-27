require 'spec_helper'

describe HealthManager do

  NatsBasedKnownStateProvider = HealthManager::NatsBasedKnownStateProvider

  include HealthManager::Common

  after :each do
    AppState.remove_all_listeners
  end

  describe AppStateProvider do
    describe NatsBasedKnownStateProvider do

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

        app = make_app({'num_instances' => 4 })

        app1 = @nb.get_droplet(app.id)

        #setting the expected state, as an expected_state_provider would
        app1.live_version  = app.live_version
        app1.state         = app.state
        app1.num_instances = app.num_instances
        app1.framework     = app.framework
        app1.runtime       = app.runtime
        app1.last_updated  = app.last_updated

        instance = app1.get_instance(@version, 0)
        instance['state'].should == 'DOWN'
        instance['last_heartbeat'].should be_nil

        hb = make_heartbeat([app])
        @nb.process_heartbeat(hb.to_json)

        instance = app1.get_instance(@version, 0)
        instance['state'].should == 'RUNNING'
        instance['last_heartbeat'].should_not be_nil

      end
    end
  end

  def make_app(options = {})
    @app_id ||= 0
    @app_id += 1
    @version = '123456'
    app = AppState.new(@app_id)
    {
      'num_instances' => 2,
      'framework' => 'sinatra',
      'runtime' => 'ruby18',
      'live_version' => @version,
      'state' => ::HealthManager::STARTED,
      'last_updated' => now

    }.merge(options).each { |k, v|
      app.send "#{k}=", v
    }
    app
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

require File.join(File.dirname(__FILE__), '..', 'spec_helper')

VCAP::Logging.setup_from_config({'level' => ENV['LOG_LEVEL'] || 'warn'})

module HealthManager::Common

  def in_em(timeout = 2)
    EM.run do
      EM.add_timer(timeout) do
        EM.stop
      end
      yield
    end
  end

  def make_app(id=1)
    app = AppState.new(id)
    expected = [
                4,
                'STARTED',
                '12345abcded',
                'sinatra',
                'ruby19',
                Time.now.to_i - 60*60*24
               ]

    app.set_expected_state(*expected)
    return app, expected
  end

  def make_heartbeat(apps)
    hb = []
    apps.each do |app|
      app.num_instances.times {|index|
        hb << {
          'droplet' => app.id,
          'version' => app.live_version,
          'instance' => "#{app.live_version}-#{index}",
          'index' => index,
          'state' => ::HealthManager::RUNNING,
          'state_timestamp' => now
        }
      }
    end
    {'droplets' => hb, 'dea' => '123456789abcdefgh'}
  end
end

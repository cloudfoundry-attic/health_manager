def in_em(timeout = 2)
  EM.run do
    EM.add_timer(timeout) do
      EM.stop
    end
    yield
  end
end

def make_app(options = {})
  app = AppState.new(options[:id] || 1)
  expected = {
    :num_instances => 4,
    :state         => 'STARTED',
    :live_version  => '12345abcded',
    :framework     => 'sinatra',
    :runtime       => 'ruby19',
    :package_state => 'STAGED',
    :last_updated  => Time.now.to_i - 60*60*24
  }.merge(options)

  app.set_expected_state(expected)
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
        'state_timestamp' => now,
        'cc_partition' => 'default'
      }
    }
  end
  {'droplets' => hb, 'dea' => '123456789abcdefgh'}
end

def make_crash_message(app, options={})
  make_exited_message(app,
                      {'reason' => 'CRASHED',
                        'crash_timestamp' => now,
                      }.merge(options))
end

def make_exited_message(app, options={})
  index = options['index'] || 0
  {
    'droplet' => app.id,
    'version' => app.live_version,
    'instance' => app.get_instance(index)['instance'] || "instance_id_#{index}",
    'index' => index,
    'reason' => 'STOPPED',
    'cc_partition' => 'default',
  }.merge(options)
end

def in_em(timeout = 2)
  EM.run do
    EM.add_timer(timeout) { EM.stop }
    yield
  end
end

def done
  raise "reactor not running" unless ::EM.reactor_running?
  ::EM.next_tick { ::EM.stop_event_loop }
end

def make_desired_droplet(options={})
  { 'instances' => options[:num_instances] || 4,
    'state' => 'STARTED',
    'version' => '12345abcded',
    'package_state' => 'STAGED',
    'updated_at' => Time.now.to_s
  }.merge(options)
end

def make_app(options = {})
  app = HealthManager::Droplet.new(options[:id] || 1)
  desired_droplet = make_desired_droplet(options)
  app.set_desired_state(desired_droplet)
  [app, desired_droplet]
end

def make_bulk_entry(options={})
  {
    'instances'     => 4,
    'state'         => 'STARTED',
    'version'       => '12345abcded',
    'package_state' => 'STAGED',
    'memory'        => 256,
    'updated_at'    => Time.now.utc.to_s
  }
end

def make_heartbeat(droplets, options={})
  hb = []
  droplets.each do |droplet|
    droplet.num_instances.times { |index|
      app_live_version = options[:app_live_version] || droplet.live_version

      hb << {
        'droplet' => droplet.id,
        'version' => app_live_version,
        'instance' => "#{app_live_version}-#{index}",
        'index' => index,
        'state' => options[:state] || HealthManager::RUNNING,
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

def make_update_message(app, options={})
  index = options['index'] || 0
  {
    'droplet' => app.id,
    'version' => app.live_version,
    'instance' => app.get_instance(index)['instance'] || "instance_id_#{index}",
    'index' => index,
    'reason' => 'RUNNING',
    'cc_partition' => 'default',
  }.merge(options)
end

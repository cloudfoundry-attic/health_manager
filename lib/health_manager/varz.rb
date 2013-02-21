# concrete varz-s for the new healthmanager, backward-compatible with old.

module HealthManager
  class Varz < VarzCommon
    include HealthManager::Common

    REALTIME_STATS = [:total_apps,
                      :total_instances,
                      :running_instances,
                      :missing_instances,
                      :crashed_instances,
                      :flapping_instances,
                      :running]

    EXPECTED_STATS = [:total,
                      :users,
                      :apps]

    def prepare
      declare_counter :total_apps
      declare_counter :total_instances
      declare_counter :running_instances
      declare_counter :missing_instances
      declare_counter :crashed_instances
      declare_counter :flapping_instances

      declare_node :running
      declare_node :running, :frameworks
      declare_node :running, :runtimes

      declare_counter :total_users
      declare_collection :users # FIXIT: ensure can be safely removed
      declare_collection :apps # FIXIT: ensure can be safely removed

      declare_node :total
      declare_node :total, :frameworks
      declare_node :total, :runtimes

      declare_counter :queue_length

      declare_counter :heartbeat_msgs_received
      declare_counter :droplet_exited_msgs_received
      declare_counter :droplet_updated_msgs_received
      declare_counter :healthmanager_status_msgs_received
      declare_counter :healthmanager_health_request_msgs_received

      declare_counter :analysis_loop_duration
      declare_counter :bulk_update_loop_duration

      declare_counter :varz_publishes
      declare_counter :varz_holds
      declare_node    :droplets # FIXIT: remove once ready for production
    end

    def reset_realtime_stats
      REALTIME_STATS.each { |s| hold(s); reset(s) }
    end

    def reset_expected_stats
      @expected_stats_reset_at = Time.now
      EXPECTED_STATS.each { |s| hold(s); reset(s) }
    end

    def release_realtime_stats
      REALTIME_STATS.each { |s| release(s) }
    end

    def release_expected_stats
      EXPECTED_STATS.each { |s| release(s) }
    end

    def publish_realtime_stats
      release_realtime_stats
      publish
    end

    def publish_expected_stats
      set(:bulk_update_loop_duration, Time.now - @expected_stats_reset_at)
      release_expected_stats
      publish
    end

    def update_realtime_stats_for_droplet(droplet)
      inc(:total_apps)
      add(:total_instances, droplet.num_instances)
      add(:crashed_instances, droplet.crashes.size)

      if droplet.state == STARTED && droplet.framework && droplet.runtime

        #top-level running/missing/flapping stats, i.e., empty path prefix
        update_state_stats_for_instances(droplet)

        ['framework', 'runtime'].each do |metric|
          path = [:running, "#{metric}s".to_sym, droplet.send(metric) ]

          #e.g., [:running, :frameworks, 'sinatra']
          #or,   [:running, :runtimes, 'ruby19' ]

          create_realtime_metrics(*path)

          inc(*path, :apps)
          add(*path, :crashes, droplet.crashes.size)

          #per framework, per runtime  running/missing/flapping stats
          update_state_stats_for_instances(*path, droplet)
        end
      end
    end

    def update_state_stats_for_instances(*path, droplet)

      droplet.num_instances.times do |index|
        instance = droplet.get_instance(droplet.live_version, index)
        case instance['state']
        when STARTING, RUNNING
          inc(*path, :running_instances)
        when DOWN
          inc(*path, :missing_instances)
        when FLAPPING
          inc(*path, :flapping_instances)
        end
      end
    end

    def update_expected_stats_for_droplet(droplet_hash)
      ['framework', 'runtime'].each do |metric|
        path = [:total, "#{metric}s".to_sym, droplet_hash[metric]]

        create_db_metrics(*path)

        inc(*path, :apps)
        add(*path, :instances, droplet_hash['instances'])
        add(*path, :memory, droplet_hash['memory'] * droplet_hash['instances'])

        if droplet_hash['state'] == STARTED
          inc(*path, :started_apps)
          add(*path, :started_instances, droplet_hash['instances'])
          add(*path, :started_memory, droplet_hash['memory'] * droplet_hash['instances'])
        end
      end
    end

    private
    def create_realtime_metrics(*path)
      declare_node(*path)
      set(*path, {
            :apps => 0,
            :crashes => 0,
            :running_instances => 0,
            :missing_instances => 0,
            :flapping_instances => 0
          }) if get(*path).empty?
    end
    def create_db_metrics(*path)
      declare_node(*path)
      set(*path, {
            :apps => 0,
            :started_apps => 0,
            :instances => 0,
            :started_instances => 0,
            :memory => 0,
            :started_memory => 0
          }) if get(*path).empty?
    end
  end
end

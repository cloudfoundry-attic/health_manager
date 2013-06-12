require 'set'

module HealthManager
  #this class provides answers about droplet's State
  class Droplet
    include HealthManager::Common

    class << self
      attr_accessor :heartbeat_deadline
      attr_accessor :desired_state_update_deadline
      attr_accessor :flapping_timeout
      attr_accessor :flapping_death
      attr_accessor :droplet_gc_grace_period
    end

    attr_reader :id
    attr_reader :state
    attr_reader :live_version
    attr_reader :num_instances
    attr_reader :package_state
    attr_reader :last_updated
    attr_reader :versions, :crashes, :extra_instances
    attr_reader :pending_restarts
    attr_accessor :desired_state_update_required

    def initialize(id)
      @id = id.to_s
      @num_instances = 0
      @versions = {}
      @crashes = {}
      @pending_restarts = {}
      @extra_instances = []
      reset_missing_indices

      # start out as stale until desired state is set
      @desired_state_update_required = true
      @desired_state_update_timestamp = now
    end

    def ripe_for_gc?
      timestamp_older_than?(@desired_state_update_timestamp, Droplet.droplet_gc_grace_period)
    end

    def set_desired_state(desired_droplet)
      logger.debug { "bulk: #set_desired_state: actual: #{self.inspect} desired_droplet: #{desired_droplet.inspect}" }

      %w[state instances version package_state updated_at].each do |k|
        unless desired_droplet[k]
          raise ArgumentError, "Value #{k} is required, missing from #{desired_droplet}"
        end
      end

      @num_instances = desired_droplet['instances']
      @state = desired_droplet['state']
      @live_version = desired_droplet['version']
      @package_state = desired_droplet['package_state']
      @last_updated = parse_utc(desired_droplet['updated_at'])

      @desired_state_update_required = false
      @desired_state_update_timestamp = now
    end

    def to_json(*a)
      encode_json(self.instance_variables.inject({}) do |h, v|
        h[v[1..-1]] = self.instance_variable_get(v); h
      end)
    end

    def restart_pending?(index)
      @pending_restarts.has_key?(index)
    end

    def add_pending_restart(index, receipt)
      @pending_restarts[index] = receipt
    end

    def remove_pending_restart(index)
      @pending_restarts.delete(index)
    end

    def process_heartbeat(beat)
      instance = get_instance(beat['version'], beat['index'])

      if running_state?(beat)
        if instance['state'] == RUNNING && instance['instance'] != beat['instance']
          @extra_instances << [beat['instance'],
            "Instance mismatch, actual: #{beat['instance']}, desired: #{instance['instance']}"]
        else
          instance['last_heartbeat'] = now
          instance['timestamp'] = now
          %w(instance state_timestamp state).each { |key|
            instance[key] = beat[key]
          }
        end
      elsif beat['state'] == CRASHED
        @crashes[beat['instance']] = {
          'timestamp' => now,
          'crash_timestamp' => beat['state_timestamp']
        }
      end
    end

    def has_missing_indices?
      # TODO: add test
      !reset_recently? && !missing_indices.empty?
    end

    def update_extra_instances
      @extra_instances = []

      # first, go through each version and prune indices
      versions.each do |version, version_entry|
        version_entry['instances'].delete_if do |index, instance|  # deleting extra instances

          if running_state?(instance) && timestamp_older_than?(instance['timestamp'], Droplet.heartbeat_deadline)
            instance['state'] = DOWN
            instance['state_timestamp'] = now
          end

          prune_reason = [[state == STOPPED, 'Droplet state is STOPPED'],
                          [index >= num_instances, 'Extra instance'],
                          [version != live_version, 'Live version mismatch']
                         ].find { |condition, _| condition }

          if prune_reason
            logger.debug1 { "pruning: #{prune_reason.last}" }
            if running_state?(instance)
              reason = prune_reason.last
              @extra_instances << [instance['instance'], reason]
            end
          end

          prune_reason #prune when non-nil
        end
      end

      delete_versions_without_instances
    end

    def reset_missing_indices
      @reset_timestamp = now
    end

    def missing_indices
      return [] unless [
                        @state == STARTED,
                        @package_state == STAGED
                        # possibly add other sanity checks here to ensure valid running state,
                        # e.g. valid version, etc.
                       ].all?


      (0...num_instances).find_all do |i|
        instance = get_instance(live_version, i)
        logger.debug1 { "looking at instance #{@id}:#{i}: #{instance}" }
        lhb = instance['last_heartbeat']
        [
         instance['state'] == CRASHED,
         lhb.nil?,
         lhb && timestamp_older_than?(lhb, Droplet.heartbeat_deadline)
        ].any? && !restart_pending?(i)
      end
    end

    def prune_crashes
      @crashes.delete_if { |_, crash|
        timestamp_older_than?(crash['timestamp'], Droplet.flapping_timeout)
      }
    end

    def num_instances= val
      @num_instances = val
      reset_missing_indices
      @num_instances
    end

    def running_state?(instance)
      instance && instance['state'] && RUNNING_STATES.include?(instance['state'])
    end

    def reset_recently?
      timestamp_fresher_than?(@reset_timestamp, Droplet.heartbeat_deadline || 0)
    end

    def desired_state_update_required?
      @desired_state_update_required
    end

    def process_exit_crash(message)
      instance = get_instance(message['version'], message['index'])
      instance['state'] = CRASHED

      instance['instance'] ||= message['instance']
      if instance['instance'] != message['instance']
        logger.warn { "unexpected instance_id: #{message['instance']}, desired: #{instance['instance']}" }
      end

      instance['crashes'] = 0 if timestamp_older_than?(instance['crash_timestamp'], Droplet.flapping_timeout)
      instance['crashes'] += 1
      instance['crash_timestamp'] = message['crash_timestamp']

      if instance['crashes'] > Droplet.flapping_death
        instance['state'] = FLAPPING
      end

      @crashes[instance['instance']] = {
        'timestamp' => now,
        'crash_timestamp' => message['crash_timestamp']
      }
    end

    def mark_instance_as_down(version, index, instance_id)
      instance = get_instance(version, index)
      if instance['instance'] == instance_id
        logger.debug("Marking as down: #{version}, #{index}, #{instance_id}")
        instance['state'] = DOWN
      elsif instance['instance']
        logger.warn("instance mismatch. actual: #{instance_id}, desired: #{instance['instance']}")
      else
        # NOOP for freshly created instance with nil instance_id
      end
    end

    def all_instances
      @versions.map { |_, v| v["instances"].values }.flatten
    end

    def get_version(version = @live_version)
      @versions[version] ||= {'instances' => {}}
    end

    def get_instances(version = @live_version)
      get_version(version)['instances']
    end

    def get_instance(version = @live_version, index)
      get_instances(version)[index] ||= {
        'state' => DOWN,
        'crashes' => 0,
        'crash_timestamp' => -1,
        'last_action' => -1
      }
    end

    def update_realtime_varz(varz)
      varz[:total_apps] += 1
      varz[:total_instances] += num_instances
      varz[:crashed_instances] += crashes.size

      if state == STARTED
        varz[:running][:apps] += 1

        num_instances.times do |index|
          instance = get_instance(live_version, index)
          case instance['state']
            when STARTING, RUNNING
              varz[:running_instances] += 1
              varz[:running][:running_instances] += 1
            when DOWN
              varz[:missing_instances] += 1
              varz[:running][:missing_instances] += 1
            when FLAPPING
              varz[:flapping_instances] += 1
              varz[:running][:flapping_instances] += 1
          end
        end

        varz[:running][:crashes] += crashes.size
      end
    end

    def is_extra?
      desired_state_update_overdue?
    end

    private

    def delete_versions_without_instances
      versions.delete_if do |version, version_entry|
        if version_entry['instances'].empty?
          @state == STOPPED || version != @live_version
        end
      end
    end

    def desired_state_update_overdue?
      timestamp_older_than?(
        @desired_state_update_timestamp,
        Droplet.desired_state_update_deadline,
      )
    end

    def timestamp_fresher_than?(timestamp, age)
      timestamp > 0 && now - timestamp < age
    end

    def timestamp_older_than?(timestamp, age)
      timestamp > 0 && (now - timestamp) > age
    end

    def parse_utc(time)
      Time.parse(time).to_i
    end
  end
end

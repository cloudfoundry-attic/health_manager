require 'set'
require 'health_manager/heartbeat'

module HealthManager
  #this class provides answers about droplet's State
  class Droplet
    include HealthManager::Common

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
      @extra_instances = {}
      reset_missing_indices

      # start out as stale until desired state is set
      @desired_state_update_required = true
      @desired_state_update_timestamp = now

    end

    def ripe_for_gc?
      timestamp_older_than?(@desired_state_update_timestamp, interval(:droplet_gc_grace_period))
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
      instance = get_instance(beat.index, beat.version)

      if beat.starting_or_running?
        if instance.running? && instance.instance_guid != beat.instance_guid
          @extra_instances[beat.instance_guid] = {
            version: beat.version,
            reason: "Instance mismatch, actual: #{beat.instance_guid}, desired: #{instance.instance_guid}"
          }
        else
          instance.update_from(beat)
        end
      elsif beat.state == CRASHED
        @crashes[beat.instance_guid] = {
          'timestamp' => now,
          'crash_timestamp' => beat.state_timestamp
        }
      end
    end

    def has_missing_indices?
      # TODO: add test
      !reset_recently? && !missing_indices.empty?
    end

    def update_extra_instances
      @extra_instances = {}

      num_running = 0

      # first, go through each version and prune indices
      versions.each do |version, version_entry|
        version_entry['instances'].delete_if do |_, instance|  # deleting extra instances
          if instance.starting_or_running? && instance.timestamp_older_than?(interval(:droplet_lost))
            instance.down!
          end

          prune_reason =
            if state == STOPPED
              "Droplet state is STOPPED"
            elsif num_running >= num_instances
              "Extra instance"
            elsif version != live_version
              "Live version mismatch"
            end

          if prune_reason
            logger.debug1 { "pruning: #{prune_reason}" }
            if instance.starting_or_running?
              @extra_instances[instance.instance_guid] = {
                version: version,
                reason: prune_reason
              }
            end

            true
          else
            num_running += 1

            false
          end
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
        instance = get_instance(i)
        logger.debug1 { "looking at instance #{@id}:#{i}: #{instance}" }
        lhb = instance.last_heartbeat
        [
         instance.crashed?,
         lhb.nil?,
         lhb && timestamp_older_than?(lhb, interval(:droplet_lost))
        ].any? && !restart_pending?(i)
      end
    end

    def prune_crashes
      @crashes.delete_if { |_, crash|
        timestamp_older_than?(crash['timestamp'], interval(:flapping_timeout))
      }
    end

    def num_instances= val
      @num_instances = val
      reset_missing_indices
      @num_instances
    end

    def reset_recently?
      timestamp_fresher_than?(@reset_timestamp, interval(:droplet_lost) || 0)
    end

    def desired_state_update_required?
      @desired_state_update_required
    end

    def process_exit_crash(message)
      instance = get_instance(message['index'], message['version'], message['instance'])
      instance.crash!(interval(:flapping_timeout), interval(:flapping_death), message['crash_timestamp'])

      if instance.instance_guid != message['instance']
        logger.warn { "unexpected instance_id: #{message['instance']}, desired: #{instance.instance_guid}" }
      end

      @crashes[instance.instance_guid] = {
        'timestamp' => now,
        'crash_timestamp' => instance.crash_timestamp
      }
    end

    def mark_instance_as_down(version, index, instance_id)
      instance = get_instance(index, version)
      if instance.instance_guid == instance_id
        logger.debug("Marking as down: #{version}, #{index}, #{instance_id}")
        instance.down!
      elsif instance.instance_guid
        logger.warn("instance mismatch. actual: #{instance_id}, desired: #{instance.instance_guid}")
      else
        # NOOP for freshly created instance with nil instance_id
      end
    end

    def all_instances
      versions.map { |_, v| v["instances"].values }.flatten
    end

    def get_version(version = @live_version)
      versions[version] ||= {'instances' => {}}
    end

    def get_instances(version = @live_version)
      get_version(version)['instances']
    end

    def get_instance(index, version = @live_version, instance_guid = nil, safe = false)
      get_instances(version)[index] ||= Heartbeat.fresh(instance_guid)
    end

    def safe_get_instance(index, version = @live_version)
      get_instances(version)[index]
    end

    def update_realtime_varz(varz)
      varz[:total_apps] += 1
      varz[:total_instances] += num_instances
      varz[:crashed_instances] += crashes.size

      if state == STARTED
        varz[:running][:apps] += 1

        num_instances.times do |index|
          instance = get_instance(index)
          case instance.state
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
      timestamp_older_than?(@desired_state_update_timestamp, interval(:desired_state_lost),)
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

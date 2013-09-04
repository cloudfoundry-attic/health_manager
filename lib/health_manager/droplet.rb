require 'set'
require 'health_manager/app_instance'

module HealthManager
  #this class provides answers about droplet's State
  class Droplet
    include HealthManager::Common

    attr_reader :id, :state, :live_version, :num_instances, :package_state, :last_updated, :crashes, :extra_instances
    attr_accessor :desired_state_update_required

    def initialize(id)
      @id = id.to_s
      @num_instances = 0
      @versions = {}
      @crashes = {}
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
      logger.debug("bulk: #set_desired_state", { actual: { instances: all_instances_report }, desired_droplet: desired_droplet })

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

    def pending_restarts
      (0..num_instances).map do |i|
        instance = get_instance(i)
        instance.pending_restart? ? instance : nil
      end.compact
    end

    def process_heartbeat(beat)
      @extra_instances.clear
      instance = get_instance(beat.index, beat.version)
      instance.receive_heartbeat(beat)
      instance_guid_to_prune = instance.extra_instance_guid_to_prune
      if instance_guid_to_prune
        @extra_instances[instance_guid_to_prune] = {
          version: beat.version,
          reason: "Instance mismatch, pruning: #{instance_guid_to_prune}"
        }
      end

      if beat.state == CRASHED
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
      @extra_instances.clear

      num_running = 0

      # first, go through each version and prune indices
      versions.each do |version, version_entry|
        version_entry['instances'].delete_if do |_, instance|  # deleting extra instances
          if instance.starting_or_running? && !instance.has_recent_heartbeat?
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
              @extra_instances[instance.guid] = {
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
        instance.missing?
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
      instance = get_instance(message.fetch(:index), message.fetch(:version), message.fetch(:instance))
      instance.crash!(message.fetch(:crash_timestamp))

      if instance.guid != message.fetch(:instance)
        logger.warn { "unexpected instance_id: #{message.fetch(:instance)}, desired: #{instance.guid}" }
      end

      @crashes[instance.guid] = {
        'timestamp' => now,
        'crash_timestamp' => instance.last_crash_timestamp
      }
    end

    def mark_instance_as_down(version, index, instance_id)
      get_instance(index, version).mark_as_down_for_guid(instance_id)
    end

    def all_starting_or_running_instances
      versions.inject([]) do |memo, (version, _)|
        get_instances(version).each { |_, instance| memo << instance if instance.starting_or_running?}
        memo
      end
    end

    def get_instances(version = @live_version)
      get_version(version)['instances']
    end

    def get_instance(index, version = @live_version, instance_guid = nil)
      get_instances(version)[index] ||= AppInstance.new(version, index, instance_guid)
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

    def number_of_running_instances_by_version
      versions.inject({}) do |memo, (version, version_entry)|
        memo[version] = version_entry["instances"].inject(0) { |memo, (_, instance)| memo + instance.running_guid_count }
        memo
      end
    end

    private
    attr_reader :versions

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

    def get_version(version = @live_version)
      versions[version] ||= {'instances' => {}}
    end

    def all_instances_report
      versions.inject([]) do |memo, (version, _)|
        get_instances(version).each { |_, instance| memo << {state: instance.state, version: instance.version, guid: instance.guid, index: instance.index, crash_count: instance.crash_count} }
        memo
      end
    end
  end
end

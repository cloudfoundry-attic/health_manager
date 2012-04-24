require 'set'

module HealthManager
  #this class provides answers about droplet's State
  class AppState
    include HealthManager::Common
    class << self
      attr_accessor :heartbeat_deadline
      attr_accessor :flapping_timeout
      attr_accessor :flapping_death

      def known_event_types
        [:missing_instances,
         :extra_instances,
         :exit_crashed,
         :exit_stopped,
         :exit_dea,
         :droplet_updated]
      end

      def add_listener(event_type, &block)
        check_event_type(event_type)
        @listeners ||= {}
        @listeners[event_type] ||= []
        @listeners[event_type] << block
      end

      def notify_listener(event_type, app_state, *args)
        check_event_type(event_type)
        listeners = @listeners[event_type] || []
        listeners.each do |block|
          block.call(app_state, *args)
        end
      end

      def check_event_type(event_type)
        raise ArgumentError, "Unknown event type: #{event_type}" unless known_event_types.include?(event_type)
      end

      def remove_all_listeners
        @listeners = {}
      end
    end

    attr_reader   :id
    attr_accessor :state
    attr_accessor :live_version
    attr_accessor :num_instances
    attr_accessor :framework, :runtime
    attr_accessor :last_updated
    attr_accessor :versions, :crashes

    def initialize(id)
      @id = id
      @num_instances = 0
      @versions = {}
      @crashes = {}
      reset_missing_indices
    end

    def notify(event_type, *args)
      self.class.notify_listener(event_type, self, *args)
    end

    def to_json(*a)
      { "json_class" => self.class.name,
      }.merge(self.instance_variables.inject({}) {|h,v|
                h[v] = self.instance_variable_get(v); h
              }).to_json(*a)
    end

    def process_heartbeat(beat)
      events = []

      instance = get_instance(beat['version'], beat['index'])
      instance['last_heartbeat'] = now

      instance['timestamp'] = now
      %w(instance state_timestamp state).each { |key|
        instance[key] = beat[key]
      }
    end

    def check_for_missing_indices
      unless reset_recently? or missing_indices.empty?
        notify(:missing_instances,  missing_indices)
        reset_missing_indices
      end
    end

    def check_and_prune_extra_indices
      extra_instances = []

      # first, go through each version and prune indices
      @versions.each do |version, version_entry |
        version_entry['instances'].delete_if do |index, instance|  # deleting extra instances

          if RUNNING_STATES.include?(instance['state']) &&
              timestamp_older_than?(instance['timestamp'],
                                    AppState.heartbeat_deadline)
            instance['state'] = DOWN
            instance['state_timestamp'] = now
          end

          prune_reason = [[@state == STOPPED, 'Droplet state is STOPPED'],
                   [index >= @num_instances, 'Extra instance'],
                   [version != @live_version, 'Live version mismatch']
                  ].find { |condition, _| condition }

          if prune_reason
            if RUNNING_STATES.include?(instance['state'])
              reason = prune_reason.last
              extra_instances << [instance['instance'], reason]
            end
          end
          prune_reason #prune when non-nil
        end
      end

      # now, prune versions
      @versions.delete_if do |version, version_entry|
        if version_entry['instances'].empty?
          @state == STOPPED || version != @live_version
        end
      end

      unless extra_instances.empty?
        notify(:extra_instances, extra_instances)
      end
    end

    def reset_missing_indices
      @reset_timestamp = now
    end

    def missing_indices
      return [] unless @state == STARTED

      (0...num_instances).find_all do |i|
        instance = get_instance(live_version, i)
        lhb = instance['last_heartbeat']
        [
         instance['state'] == CRASHED,
         lhb.nil?,
         lhb && timestamp_older_than?(lhb, AppState.heartbeat_deadline)
        ].any?
      end
    end

    def prune_crashes
      @crashes.delete_if { |_, crash|
        timestamp_older_than?(crash['timestamp'], AppState.flapping_timeout)
      }
    end

    def num_instances= val
      @num_instances = val
      reset_missing_indices
      @num_instances
    end

    #check for all anomalies and trigger appropriate events so that listeners can take action
    def analyze
      check_for_missing_indices
      check_and_prune_extra_indices
      prune_crashes
    end

    def reset_recently?
      timestamp_fresher_than?(@reset_timestamp, AppState.heartbeat_deadline || 0)
    end

    def process_exit_dea(message)
      notify(:exit_dea, message)
    end

    def process_exit_stopped(message)
      reset_missing_indices
      @state = STOPPED
      notify(:exit_stopped, message)
    end

    def process_exit_crash(message)
      instance = get_instance(message['version'],message['index'])
      instance['state'] = CRASHED

      instance['crashes'] = 0 if timestamp_older_than?(instance['crash_timestamp'], AppState.flapping_timeout)

      instance['crashes'] += 1
      instance['crash_timestamp'] = message['crash_timestamp']

      if instance['crashes'] > AppState.flapping_death
        instance['state'] = FLAPPING
      end

      @crashes[instance['instance']] = {
        'timestamp' => now,
        'crash_timestamp' => message['crash_timestamp']
      }
      notify(:exit_crashed, message)
    end

    def process_droplet_updated(message)
      reset_missing_indices
      notify(:droplet_updated, message)
    end

    def get_version(version)
      @versions[version] ||= {'instances'=>{}}
    end

    def get_instances(version)
      get_version(version)['instances']
    end

    def get_instance(version, index)
      get_instances(version)[index] ||= {
        'state' => DOWN,
        'crashes' => 0,
        'crash_timestamp' => -1,
        'last_action' => -1
      }
    end
  end
end

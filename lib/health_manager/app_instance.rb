require 'health_manager/heartbeat'
require 'health_manager/stateful_object'

module HealthManager
  class AppInstance
    include StatefulObject
    include HealthManager::Common

    attr_reader :state, :guid, :index, :pending_restart_receipt, :last_crash_timestamp, :state_timestamp, :crash_count, :version

    def initialize(version, index, guid)
      @version = version
      @index = index
      @guid = guid
      reset_crash_count
      @last_crash_timestamp = nil
      @guid_stream = []
      down!
    end

    def down!
      @state = 'DOWN'
      @state_timestamp = now
    end

    def crash!(timestamp)
      @state = 'CRASHED'

      reset_crash_count if last_crash_long_ago?(timestamp)

      @crash_count += 1
      @last_crash_timestamp = timestamp

      @state = 'FLAPPING' if too_many_crash_count?
    end

    def receive_heartbeat(heartbeat)
      if heartbeat.starting_or_running?
        @guid_stream << heartbeat.instance_guid

        @last_heartbeat_time = now
        @guid = heartbeat.instance_guid
        @state = heartbeat.state
        @state_timestamp = heartbeat.state_timestamp
      else
        remove_guid_from_guid_stream(heartbeat.instance_guid)
      end
    end

    def extra_instance_guid_to_prune
      return nil if @guid_stream.count < 3
      @guid_stream = @guid_stream.last(3)
      return nil if @guid_stream[0] == @guid_stream[1]
      @guid_stream.detect {|guid| guid != @guid}
    end

    def running_guid_count
      running? ? @guid_stream.uniq.size : 0
    end

    def alive?
      !crashed? && has_recent_heartbeat?
    end

    def missing?
      !alive? && !pending_restart?
    end

    def has_recent_heartbeat?
      !@last_heartbeat_time.nil? && !timestamp_older_than?(@last_heartbeat_time, Config.interval(:droplet_lost))
    end

    def pending_restart?
      !pending_restart_receipt.nil?
    end

    def mark_pending_restart_with_receipt!(receipt)
      @pending_restart_receipt = receipt
    end

    def unmark_pending_restart!
      @pending_restart_receipt = nil
    end

    def giveup_restarting?
      interval = Config.interval(:giveup_crash_number)
      interval > 0 && @crash_count > interval
    end

    def mark_as_down_for_guid(affected_guid)
      return unless guid == affected_guid

      logger.debug("hm.instance.marking-as-down", version: version, index: index, guid: guid)
      remove_guid_from_guid_stream(guid)
      down!
    end

    private

    def remove_guid_from_guid_stream(guid)
      @guid_stream.delete(guid)
    end

    def timestamp_older_than?(timestamp, interval)
      timestamp > 0 && (now - timestamp) > interval
    end

    def reset_crash_count
      @crash_count = 0
    end

    def last_crash_long_ago?(timestamp)
      @last_crash_timestamp && (timestamp - @last_crash_timestamp > Config.interval(:flapping_timeout))
    end

    def too_many_crash_count?
      @crash_count > Config.interval(:flapping_death)
    end
  end
end
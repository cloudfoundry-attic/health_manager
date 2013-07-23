require 'health_manager/heartbeat'
require 'health_manager/stateful_object'

module HealthManager
  class AppInstance
    include StatefulObject

    attr_reader :state, :guid, :index, :pending_restart_receipt, :last_crash_timestamp, :state_timestamp, :crash_count, :version

    def initialize(version, index, guid)
      @version = version
      @index = index
      @guid = guid
      reset_crash_count
      @last_crash_timestamp = nil
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
      @last_heartbeat_time = now
      @guid = heartbeat.instance_guid
      @state = heartbeat.state
      @state_timestamp = heartbeat.state_timestamp
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

    private

    def timestamp_older_than?(timestamp, interval)
      timestamp > 0 && (now - timestamp) > interval
    end

    def now
      ::HealthManager::Manager.now
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
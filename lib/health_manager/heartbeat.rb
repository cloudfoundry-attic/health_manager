module HealthManager
  class Heartbeat
    attr_reader :last_heartbeat, :timestamp

    def initialize(hash={}, last_heartbeat = now)
      @hash = hash
      @last_heartbeat = @timestamp = last_heartbeat
    end

    def self.fresh(instance_guid = nil)
      new({
        'state' => DOWN,
        'crashes' => 0,
        'crash_timestamp' => -1,
        'last_action' => -1,
        'instance' => instance_guid
      }, nil
      )
    end

    def state
      @hash['state']
    end

    def state_timestamp
      @hash['state_timestamp']
    end

    def crashes
      @hash['crashes']
    end

    def crash_timestamp
      @hash['crash_timestamp']
    end

    def last_action
      @hash['last_action']
    end

    def instance_guid
      @hash['instance']
    end

    def version
      @hash['version']
    end

    def index
      @hash['index']
    end

    def starting_or_running?
      %w[STARTING RUNNING].include? state
    end

    def running?
      state == 'RUNNING'
    end

    def crashed?
      state == 'CRASHED'
    end

    def down?
      state == 'DOWN'
    end

    def starting!
      @hash['state'] = 'STARTING'
    end

    def running!
      @hash['state'] = 'RUNNING'
    end

    def down!
      @hash['state'] = 'DOWN'
      @hash['state_timestamp'] = now
    end

    def crash!(flapping_interval, flapping_death, timestamp)
      @hash['state'] = 'CRASHED'

      if crash_timestamp_older_than?(flapping_interval)
        @hash['crashes'] = 0
      end
      @hash['crashes'] += 1
      @hash['crash_timestamp'] = timestamp
      if crashes > flapping_death
        @hash['state'] = 'FLAPPING'
      end
    end

    def update_from(other)
      @last_heartbeat = now
      @timestamp = now
      @hash['instance'] = other.instance_guid
      @hash['state_timestamp'] = other.state_timestamp
      @hash['state'] = other.state
    end

    def timestamp_older_than?(interval)
      timestamp > 0 && (now - timestamp) > interval
    end

    def crash_timestamp_older_than?(interval)
      crash_timestamp > 0 && (now - crash_timestamp) > interval
    end

    def dup
      other = self.class.new(@hash.dup)
      other.instance_variable_set(:@last_heartbeat, last_heartbeat)
      other.instance_variable_set(:@timestamp, timestamp)
      other
    end

    private

    def now
      ::HealthManager::Manager.now
    end
  end
end
require 'health_manager/stateful_object'

module HealthManager
  class Heartbeat
    include StatefulObject
    attr_reader :last_heartbeat, :timestamp

    def initialize(hash={}, last_heartbeat = now)
      @hash = hash.dup
      @last_heartbeat = @timestamp = last_heartbeat
    end

    def state
      @hash.fetch(:state)
    end

    def state_timestamp
      @hash.fetch(:state_timestamp)
    end

    def instance_guid
      @hash.fetch(:instance)
    end

    def version
      @hash.fetch(:version)
    end

    def index
      @hash.fetch(:index)
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
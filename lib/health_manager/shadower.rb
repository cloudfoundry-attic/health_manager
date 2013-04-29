module HealthManager
  class Shadower
    include HealthManager::Common

    def initialize(config = {})
      @config = config
      @requests = {}
    end

    def subscribe_to_all
      ['healthmanager.start',
       'cloudcontrollers.hm.requests',
       'healthmanager.status',
       'healthmanager.health'
      ].each { |subj| subscribe(subj) }
    end

    def subscribe(subj)
      logger.info("shadower: subscribing: #{subj}")

      NATS.subscribe(subj) do |message|
        process_message(subj, message)
      end
    end

    def process_message(subj, message)
      logger.info{ "shadower: received: #{subj}: #{message}" }
      record_request(message, 1) if subj == 'cloudcontrollers.hm.requests'
    end

    def publish(subj, message)
      logger.info("shadower: publish: #{subj}: #{message}")
      record_request(message, -1) if subj == 'cloudcontrollers.hm.requests'
    end

    def record_request(message, increment)
      request = @requests[message] ||= {}

      request[:timestamp] = now
      request[:count] ||= 0
      request[:count] += increment

      @requests.delete(message) if request[:count] == 0
    end

    def check_shadowing
      max_delay = interval(:max_shadowing_delay)

      unmatched = @requests
        .find_all { |_, entry| timestamp_older_than?(entry[:timestamp], max_delay) }

      if unmatched.empty?
        logger.info("shadower: check: OK")
      else
        logger.warn("shadower: check: unmatched: found #{unmatched.size} unmatched messages, details follow")
        unmatched.each do |message, entry|
          logger.warn("shadower: check: unmatched: #{message} #{entry[:count]}")
          @requests.delete(message)
        end
      end
    end

    private

    def timestamp_older_than?(timestamp, age)
      timestamp > 0 && (now - timestamp) > age
    end
  end
end

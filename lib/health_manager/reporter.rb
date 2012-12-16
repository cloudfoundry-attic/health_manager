# Responds to status and health messages
require 'schemata/health_manager'

module HealthManager
  class Reporter
    include HealthManager::Common

    def initialize(config = {})
      @config = config
    end

    def prepare
      NATS.subscribe('healthmanager.status') { |msg, reply_to|
        msg = Schemata::HealthManager::StatusRequest.decode(msg)
        process_status_message(msg, reply_to)
      }
      NATS.subscribe('healthmanager.health') { |msg, reply_to|
        msg = Schemata::HealthManager::HealthRequest.decode(msg)
        process_health_message(msg, reply_to)
      }
    end

    def process_status_message(message, reply_to)
      varz.inc(:healthmanager_status_msgs_received)
      logger.debug { "reporter: status: message: #{message.contents}" }
      droplet_id = message.droplet.to_s

      return unless known_state_provider.has_droplet?(droplet_id)
      known_droplet = known_state_provider.get_droplet(droplet_id)
      state = message.state

      result = nil
      case state
      when FLAPPING
        version = message.version
        result = known_droplet.get_instances(version)
          .select { |_, instance| FLAPPING == instance['state'] }
          .map { |i, instance| { :index => i, :since => instance['state_timestamp'] }}
        response = Schemata::HealthManager::StatusFlappingResponse::V1.new(
          { :indices => result }
        )
        publisher.publish(reply_to, response.encode)
      when CRASHED
        result = known_droplet.crashes.map { |instance, crash|
          { :instance => instance, :since => crash['crash_timestamp'] }
        }
        response = Schemata::HealthManager::StatusCrashedResponse::V1.new(
          { :instances => results }
        )
        publisher.publish(reply_to, response.encode)
      end
    end

    def process_health_message(message, reply_to)
      varz.inc(:healthmanager_health_request_msgs_received)
      message.droplets.each do |droplet|
        droplet_id = droplet['droplet'].to_s

        next unless known_state_provider.has_droplet?(droplet_id)

        version = droplet['version']
        known_droplet = known_state_provider.get_droplet(droplet_id)

        running = (0...known_droplet.num_instances).count { |i|
          RUNNING == known_droplet.get_instance(version, i)['state']
        }
        response = Schemata::HealthManager::HealthResponse::V1.new({
          :droplet => droplet_id,
          :version => version,
          :healthy => running
        })
        publisher.publish(reply_to, response.encode)
      end
    end
  end
end

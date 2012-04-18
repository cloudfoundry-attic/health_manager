# Responds to status messages, publishes varz and healthz through VCAP::Component

module HealthManager
  class Reporter
    include HealthManager::Common
    def initialize(config={})
      @config = config
    end

    def prepare
      NATS.subscribe('healthmanager.status') { |msg, reply|
        process_status_message(msg,reply)
      }
      NATS.subscribe('healthmanager.health') { |msg, reply|

        process_health_message(msg,reply)
      }
    end

    def process_status_message(message, reply)
      varz.inc(:healthmanager_status_msgs_received)
      message = parse_json(message)
      logger.debug { "reporter: status: message: #{message}" }
      droplet_id = message['droplet']

      return unless known_state_provider.has_droplet?(droplet_id)
      known_droplet = known_state_provider.get_droplet(droplet_id)
      state = message['state']

      result = nil
      case state

      when FLAPPING
        version = message['version']
        result = known_droplet.get_instances(version).
          select { |i, instance|
          FLAPPING == instance['state']
        }.map { |i, instance|
          { :index => i, :since => instance['state_timestamp'] }
        }
        NATS.publish(reply, {:indices => result}.to_json)
      when CRASHED
        result = known_droplet.crashes.map { |instance, crash|
          { :instance => instance, :since => crash['crash_timestamp'] }
        }
        NATS.publish(reply, {:instances => result}.to_json)
      end
    end

    def process_health_message(message, reply)
      varz.inc(:healthmanager_health_request_msgs_received)
      message = parse_json(message)
      message['droplets'].each do |droplet|
        droplet_id = droplet['droplet']

        next unless known_state_provider.has_droplet?(droplet_id)

        version = droplet['version']
        known_droplet = known_state_provider.get_droplet(droplet_id)

        running = (0...known_droplet.num_instances).count { |i|
          RUNNING == known_droplet.get_instance(version, i)['state']
        }
        response = {
          :droplet => droplet_id,
          :version => version,
          :healthy => running
        }
        NATS.publish(reply, encode_json(response))
      end
    end

  end
end

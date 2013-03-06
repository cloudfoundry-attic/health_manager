# Responds to status and health messages

module HealthManager
  class Reporter
    include HealthManager::Common

    def initialize(config = {})
      @config = config
    end

    def prepare
      NATS.subscribe('healthmanager.status') { |msg, reply_to|
        process_status_message(msg, reply_to)
      }
      NATS.subscribe('healthmanager.health') { |msg, reply_to|
        process_health_message(msg, reply_to)
      }
      NATS.subscribe('healthmanager.droplet') { |msg, reply_to|
        process_droplet_message(msg, reply_to)
      }
    end

    def process_status_message(message, reply_to)
      varz.inc(:healthmanager_status_msgs_received)
      message = parse_json(message)
      logger.debug { "reporter: status: message: #{message}" }
      droplet_id = message['droplet'].to_s

      return unless known_state_provider.has_droplet?(droplet_id)
      known_droplet = known_state_provider.get_droplet(droplet_id)
      state = message['state']

      result = nil
      case state
      when FLAPPING
        version = message['version']
        result = known_droplet.get_instances(version)
          .select { |_, instance| FLAPPING == instance['state'] }
          .map { |i, instance| { :index => i, :since => instance['state_timestamp'] }}

        publisher.publish(reply_to, encode_json({:indices => result}))
      when CRASHED
        result = known_droplet.crashes.map { |instance, crash|
          { :instance => instance, :since => crash['crash_timestamp'] }
        }
        publisher.publish(reply_to, encode_json({:instances => result}))
      end
    end

    def process_health_message(message, reply_to)
      varz.inc(:healthmanager_health_request_msgs_received)
      message = parse_json(message)
      message['droplets'].each do |droplet|
        droplet_id = droplet['droplet'].to_s

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
        publisher.publish(reply_to, encode_json(response))
      end
    end
    def process_droplet_message(message, reply_to)
      varz.inc(:healthmanager_droplet_request_msgs_received)
      message = parse_json(message)
      message['droplets'].each do |droplet|
        droplet_id = droplet['droplet'].to_s
        next unless known_state_provider.has_droplet?(droplet_id)
        known_droplet = known_state_provider.get_droplet(droplet_id)
        publisher.publish(reply_to, encode_json(known_droplet))
      end
    end
  end
end

# Responds to status and health messages

module HealthManager
  class Reporter
    include HealthManager::Common

    attr_reader :varz, :droplet_registry, :publisher

    def initialize(config = {}, varz, droplet_registry, publisher)
      @config = config
      @varz = varz
      @droplet_registry = droplet_registry
      @publisher = publisher
    end

    def prepare
      NATS.subscribe('healthmanager.status') do |msg, reply_to|
        process_status_message(msg, reply_to)
      end
      NATS.subscribe('healthmanager.health') do |msg, reply_to|
        process_health_message(msg, reply_to)
      end
      NATS.subscribe('healthmanager.droplet') do |msg, reply_to|
        process_droplet_message(msg, reply_to)
      end
    end

    def process_status_message(message, reply_to)
      varz[:healthmanager_status_msgs_received] += 1
      message = parse_json(message)
      logger.debug { "reporter: status: message: #{message}" }
      droplet_id = message['droplet'].to_s

      return unless droplet_registry.include?(droplet_id)
      droplet = droplet_registry.get(droplet_id)
      state = message['state']

      result = nil
      case state
      when FLAPPING
        version = message['version']
        result = droplet.get_instances(version)
          .select { |_, instance| FLAPPING == instance['state'] }
          .map { |i, instance| { :index => i, :since => instance['state_timestamp'] }}

        publisher.publish(reply_to, encode_json({:indices => result}))
      when CRASHED
        result = droplet.crashes.map { |instance, crash|
          { :instance => instance, :since => crash['crash_timestamp'] }
        }
        publisher.publish(reply_to, encode_json({:instances => result}))
      end
    end

    def process_health_message(message, reply_to)
      varz[:healthmanager_health_request_msgs_received] += 1
      message = parse_json(message)
      message['droplets'].each do |droplet|
        droplet_id = droplet['droplet'].to_s

        next unless droplet_registry.include?(droplet_id)

        version = droplet['version']
        droplet = droplet_registry.get(droplet_id)

        running = (0...droplet.num_instances).count { |i|
          RUNNING == droplet.get_instance(version, i)['state']
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
      varz[:healthmanager_droplet_request_msgs_received] += 1
      message = parse_json(message)
      message['droplets'].each do |droplet|
        droplet_id = droplet['droplet'].to_s
        next unless droplet_registry.include?(droplet_id)
        droplet = droplet_registry.get(droplet_id)
        publisher.publish(reply_to, encode_json(droplet))
      end
    end
  end
end

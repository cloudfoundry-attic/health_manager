# Responds to status and health messages

module HealthManager
  class Reporter
    include HealthManager::Common

    attr_reader :varz, :droplet_registry

    def initialize(varz, droplet_registry, message_bus)
      @varz = varz
      @droplet_registry = droplet_registry
      @message_bus = message_bus
    end

    def prepare
      @message_bus.subscribe('healthmanager.status') do |msg, reply_to|
        process_status_message(msg, reply_to)
      end
      @message_bus.subscribe('healthmanager.health') do |msg, reply_to|
        process_health_message(msg, reply_to)
      end
      @message_bus.subscribe('healthmanager.droplet') do |msg, reply_to|
        process_droplet_message(msg, reply_to)
      end
    end

    def process_status_message(message, reply_to)
      varz[:healthmanager_status_msgs_received] += 1
      logger.debug { "reporter: status: message: #{message}" }
      droplet_id = message.fetch(:droplet).to_s

      return unless droplet_registry.include?(droplet_id)
      droplet = droplet_registry.get(droplet_id)
      state = message.fetch(:state)

      result = nil
      case state
      when FLAPPING
        version = message.fetch(:version)
        result = droplet.get_instances(version)
          .select { |_, instance| instance.flapping? }
          .map { |i, instance| { :index => i, :since => instance.state_timestamp }}

        @message_bus.publish(reply_to, {:indices => result})
      when CRASHED
        result = droplet.crashes.map { |instance, crash|
          { :instance => instance, :since => crash['crash_timestamp'] }
        }
        @message_bus.publish(reply_to, {:instances => result})
      end
    end

    def process_health_message(message, reply_to)
      varz[:healthmanager_health_request_msgs_received] += 1
      message.fetch(:droplets).each do |droplet_hash|
        droplet_id = droplet_hash.fetch(:droplet).to_s
        version = droplet_hash.fetch(:version)

        next unless droplet_registry.include?(droplet_id)
        droplet = droplet_registry.get(droplet_id)

        running = (0...droplet.num_instances).count do |i|
          droplet.get_instance(i, version).running?
        end

        response = {
          :droplet => droplet_id,
          :version => version,
          :healthy => running
        }
        @message_bus.publish(reply_to, response)
      end
    end

    def process_droplet_message(message, reply_to)
      varz[:healthmanager_droplet_request_msgs_received] += 1
      message.fetch(:droplets).each do |droplet|
        droplet_id = droplet.fetch(:droplet).to_s
        next unless droplet_registry.include?(droplet_id)
        droplet = droplet_registry.get(droplet_id)
        @message_bus.publish(reply_to, droplet)
      end
    end
  end
end

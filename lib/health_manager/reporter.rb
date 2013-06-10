# Responds to status and health messages

module HealthManager
  class Reporter
    include HealthManager::Common

    attr_reader :varz, :actual_state, :publisher

    def initialize(config = {}, varz, actual_state, publisher)
      @config = config
      @varz = varz
      @actual_state = actual_state
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

      return unless actual_state.has_droplet?(droplet_id)
      actual_droplet_state = actual_state.get_droplet(droplet_id)
      state = message['state']

      result = nil
      case state
      when FLAPPING
        version = message['version']
        result = actual_droplet_state.get_instances(version)
          .select { |_, instance| FLAPPING == instance['state'] }
          .map { |i, instance| { :index => i, :since => instance['state_timestamp'] }}

        publisher.publish(reply_to, encode_json({:indices => result}))
      when CRASHED
        result = actual_droplet_state.crashes.map { |instance, crash|
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

        next unless actual_state.has_droplet?(droplet_id)

        version = droplet['version']
        actual_droplet_state = actual_state.get_droplet(droplet_id)

        running = (0...actual_droplet_state.num_instances).count { |i|
          RUNNING == actual_droplet_state.get_instance(version, i)['state']
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
        next unless actual_state.has_droplet?(droplet_id)
        actual_droplet_state = actual_state.get_droplet(droplet_id)
        publisher.publish(reply_to, encode_json(actual_droplet_state))
      end
    end
  end
end


module HealthManager

  #this implementation maintains the known state by listening to the
  #DEA heartbeat messages
  class NatsBasedKnownStateProvider < KnownStateProvider
    def cc_partition_match?(message)
      cc_partition == message['cc_partition']
    end

    def check_availability
      was_available = @available
      @available = available?

      if @available && !was_available
        initialize_subscriptions
      end

      if was_available && !@available
        logger.info("connection to NATS was lost")
      end
    end

    def initialize_subscriptions
      logger.info("subscribing to heartbeats")
      NATS.subscribe('dea.heartbeat') do |message|
        process_heartbeat(message)
      end

      logger.info("subscribing to droplet.exited")
      NATS.subscribe('droplet.exited') do |message|
        process_droplet_exited(message)
      end

      logger.info("subscribing to droplet.updated")
      NATS.subscribe('droplet.updated') do |message|
        process_droplet_updated(message)
      end
    end

    def start
      check_availability
      super
    end

    def available?
      NATS.connected?
    end

    def process_droplet_exited(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug { "process_droplet_exited: #{message_str}" }
      varz[:droplet_exited_msgs_received] += 1

      droplet = get_droplet(message['droplet'].to_s)

      droplet.mark_instance_as_down(message['version'],
                                    message['index'],
                                    message['instance'])
      case message['reason']
      when CRASHED
        varz[:crashed_instances] += 1
        droplet.process_exit_crash(message)
      when DEA_SHUTDOWN, DEA_EVACUATION
        droplet.process_exit_dea(message)
      when STOPPED
        droplet.process_exit_stopped(message)
      end
    end

    def process_heartbeat(message_str)
      message = parse_json(message_str)

      logger.debug2 { "known: #process_heartbeat: #{message_str}" }
      varz[:heartbeat_msgs_received] += 1

      message['droplets'].each do |beat|
        next unless cc_partition_match?(beat)
        id = beat['droplet'].to_s
        get_droplet(id).process_heartbeat(beat)
      end
    end

    def process_droplet_updated(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug { "known: #process_droplet_updated: #{message_str}" }
      varz[:droplet_updated_msgs_received] += 1
      get_droplet(message['droplet'].to_s).process_droplet_updated(message)
    end
  end
end


module HealthManager

  #this implementation maintains the known state by listening to the
  #DEA heartbeat messages
  class NatsBasedKnownStateProvider < KnownStateProvider
    def initialize(config = {})
      @config = config
      super
    end

    def start
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

      super
    end

    def process_droplet_exited(message)
      logger.debug { "process_droplet_exited: #{message}" }
      varz.inc(:droplet_exited_msgs_received)

      message = parse_json(message)
      droplet = get_droplet(message['droplet'])

      case message['reason']
      when CRASHED
        varz.inc(:crashed_instances)
        droplet.process_exit_crash(message)
      when DEA_SHUTDOWN, DEA_EVACUATION
        droplet.process_exit_dea(message)
      when STOPPED
        droplet.process_exit_stopped(message)
      end
    end

    def process_heartbeat(message)
      logger.debug { "known: #process_heartbeat: #{message}" }
      varz.inc(:heartbeat_msgs_received)

      message = parse_json(message)
      dea_uuid = message['dea']

      message['droplets'].each do |beat|
        id = beat['droplet']
        get_droplet(id).process_heartbeat(beat)
      end
    end

    def process_droplet_updated(message)
      logger.debug { "known: #process_droplet_updated: #{message}" }
      varz.inc(:droplet_updated_msgs_received)

      message = parse_json(message)
      get_droplet(message['droplet']).process_droplet_updated(message)
    end
  end
end

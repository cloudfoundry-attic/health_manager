module HealthManager
  class ActualState
    include HealthManager::Common
    attr_reader :app_states, :varz

    def initialize(config, varz)
      @config = config
      @app_states = {} # hashes droplet_id => AppState instance
      @current_app_state_index = 0
      @app_state_ids = []
      @varz = varz
    end

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
    end

    # these methods have to do with threading and quantization
    def rewind
      @current_app_state_index = 0
      @app_state_ids = @app_states.keys
    end

    def next_droplet
      # The @droplets hash may have undergone modifications while
      # we're iterating. New items that are added will not be seen
      # until #rewind is called again. Deleted droplets will be
      # skipped over.

      droplet = nil # nil value indicates the end of the collection

      # skip over garbage-collected droplets
      while (droplet = @app_states[@app_state_ids[@current_app_state_index]]).nil? && @current_app_state_index < @app_state_ids.size
        @current_app_state_index += 1
      end

      @current_app_state_index += 1
      droplet
    end

    def has_app_state?(id)
      @app_states.has_key?(id.to_s)
    end

    def get_app_state(id)
      id = id.to_s
      @app_states[id] ||= AppState.new(id)
    end

    def available?
      NATS.connected?
    end

    def process_droplet_exited(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug { "process_droplet_exited: #{message_str}" }
      varz[:droplet_exited_msgs_received] += 1

      droplet = get_app_state(message['droplet'].to_s)

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

      logger.debug { "Actual: #process_heartbeat: #{message_str}" }
      varz[:heartbeat_msgs_received] += 1

      message['droplets'].each do |beat|
        next unless cc_partition_match?(beat)
        id = beat['droplet'].to_s
        get_app_state(id).process_heartbeat(beat)
      end
    end

    def process_droplet_updated(message_str)
      message = parse_json(message_str)
      return unless cc_partition_match?(message)

      logger.debug { "Actual: #process_droplet_updated: #{message_str}" }
      varz[:droplet_updated_msgs_received] += 1
      get_app_state(message['droplet'].to_s).process_droplet_updated(message)
    end
  end
end

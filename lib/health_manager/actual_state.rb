module HealthManager
  class ActualState
    include HealthManager::Common
    attr_reader :varz
    attr_accessor :harmonizer

    def initialize(varz, droplet_registry, message_bus)
      @droplet_registry = droplet_registry
      @varz = varz
      @message_bus = message_bus
    end

    def start
      logger.info "hm.actual-state.subscribing"

      @message_bus.subscribe('dea.heartbeat') do |message|
        process_heartbeat(message)
      end

      @message_bus.subscribe('droplet.exited') do |message|
        process_droplet_exited(message)
      end

      @message_bus.subscribe('droplet.updated') do |message|
        process_droplet_updated(message)
      end
    end

    def available?
      @message_bus.connected?
    end

    private

    def process_droplet_exited(message)
      logger.debug "hm.actual-state.process-droplet-exited",
                   :message => message

      varz[:droplet_exited_msgs_received] += 1

      droplet = get_droplet(message)

      droplet.mark_instance_as_down(message.fetch(:version),
                                    message.fetch(:index),
                                    message.fetch(:instance))

      case message.fetch(:reason)
      when CRASHED
        varz[:crashed_instances] += 1
        droplet.process_exit_crash(message)
        harmonizer.on_exit_crashed(droplet, message)
      when DEA_SHUTDOWN, DEA_EVACUATION
        droplet.reset_missing_indices
        harmonizer.on_exit_dea(droplet, message)
      when STOPPED
        droplet.reset_missing_indices
        harmonizer.on_exit_stopped(message)
      end
    end

    def process_heartbeat(message)
      logger.debug "hm.actual-state.process-heartbeat",
                   :dea => message.fetch(:dea)

      varz[:heartbeat_msgs_received] += 1

      message[:droplets].each do |beat|
        droplet = get_droplet(beat)
        droplet.process_heartbeat(Heartbeat.new(beat))
        harmonizer.on_extra_instances(droplet, droplet.extra_instances)
      end
    end

    def process_droplet_updated(message)
      logger.debug "hm.actual-state.process-droplet-updated",
                   :droplet => message.fetch(:droplet)

      varz[:droplet_updated_msgs_received] += 1
      droplet = get_droplet(message)
      droplet.reset_missing_indices
      harmonizer.on_droplet_updated(droplet, message)
    end

    def get_droplet(message)
      @droplet_registry.get(message.fetch(:droplet).to_s)
    end
  end
end

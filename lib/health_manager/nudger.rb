module HealthManager
  class Nudger
    include HealthManager::Common

    attr_reader :varz, :publisher

    def initialize(config, varz, publisher)
      @config = config
      @queue = VCAP::PrioritySet.new
      @queue_batch_size = get_interval_from_config_or_default(:queue_batch_size, @config)
      @varz = varz
      @publisher = publisher
    end

    def deque_batch_of_requests
      @queue_batch_size.times do |i|
        break if @queue.empty?
        message = encode_json(@queue.remove)
        publish_request_message(message)
      end
    end

    def publish_request_message(message)
      logger.info("nudger: publish: cloudcontrollers.hm.requests: #{message}")
      publisher.publish("cloudcontrollers.hm.requests.#{cc_partition}", message)
    end

    def start_flapping_instance_immediately(app, index)
      publish_request_message(encode_json(make_start_message(app, [index], true)))
    end

    def start_instance(app, index, priority)
      start_instances(app, [index], priority)
    end

    def start_instances(app, indices, priority)
      logger.debug { "nudger: queued: start instances #{indices} for #{app.id} priority: #{priority}" }
      queue(make_start_message(app, indices), priority)
    end

    def stop_instances_immediately(app, instances_and_reasons)
      instances_and_reasons.each do |instance, reason|
        logger.info("nudger: stopping instance #{instance} for #{app.id}, reason: #{reason}")
      end

      instances = instances_and_reasons.map { |inst, _| inst }

      publish_request_message(encode_json(make_stop_message(app, instances)))
    end

    def stop_instance(app, instance, priority)
      logger.debug { "nudger: stopping instance: app: #{app.id} instance: #{instance}" }
      queue(make_stop_message(app, instance), priority)
    end

    def make_start_message(app, indices, flapping = false)
      message = {
        :droplet => app.id,
        :op => :START,
        :last_updated => app.last_updated,
        :version => app.live_version,
        :indices => indices
      }
      message[:flapping] = true if flapping
      message
    end

    def make_stop_message(app, instance)
      {
        :droplet => app.id,
        :op => :STOP,
        :last_updated => app.last_updated,
        :instances => instance
      }
    end

    def queue(message, priority = NORMAL_PRIORITY)
      logger.debug { "nudger: queueing: #{message}, #{priority}" }
      key = message.clone
      key.delete(:last_updated)
      @queue.insert(message, priority, key)
      varz[:queue_length] = @queue.size
    end
  end
end

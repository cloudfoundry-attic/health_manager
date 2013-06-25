module HealthManager
  class Nudger
    include HealthManager::Common

    attr_reader :varz, :publisher

    def initialize(varz, publisher)
      @queue = VCAP::PrioritySet.new
      @queue_batch_size = HealthManager::Config.interval(:queue_batch_size)
      @varz = varz
      @publisher = publisher
    end

    def deque_batch_of_requests
      @queue_batch_size.times do
        break if @queue.empty?

        request = @queue.remove

        publish_request_message(
          request[:operation],
          encode_json(request[:payload]))
      end
    end

    def publish_request_message(operation, payload)
      logger.info("hm.nudger.request",
                  :operation => operation, :payload => payload)

      publisher.publish("health.#{operation}", payload)
    end

    def start_flapping_instance_immediately(app, index)
      publish_request_message("start", encode_json(make_start_message(app, [index], true)))
    end

    def start_instance(app, index, priority)
      start_instances(app, [index], priority)
    end

    def start_instances(app, indices, priority)
      logger.debug { "nudger: queued: start instances #{indices} for #{app.id} priority: #{priority}" }
      queue("start", make_start_message(app, indices), priority)
    end

    def stop_instances_immediately(app, instances_and_reasons)
      instances_and_reasons.each do |instance, reason|
        logger.info("nudger: stopping instance #{instance} for #{app.id}, reason: #{reason}")
      end

      instances = instances_and_reasons.map { |inst, _| inst }

      publish_request_message("stop", encode_json(make_stop_message(app, instances)))
    end

    def stop_instance(app, instance, priority)
      logger.debug { "nudger: stopping instance: app: #{app.id} instance: #{instance}" }
      queue("stop", make_stop_message(app, instance), priority)
    end

    def make_start_message(app, indices, flapping = false)
      {
        :droplet => app.id,
        :last_updated => app.last_updated,
        :version => app.live_version,
        :indices => indices,
        :running => running_count(app),
        :flapping => flapping
      }
    end

    def make_stop_message(app, instance)
      {
        :droplet => app.id,
        :last_updated => app.last_updated,
        :instances => instance,
        :running => running_count(app),
        :version => app.live_version
      }
    end

    def queue(operation, payload, priority = NORMAL_PRIORITY)
      logger.debug { "nudger: queueing: #{payload}, #{priority}" }
      key = payload.clone
      key.delete(:last_updated)
      @queue.insert({ operation: operation, payload: payload }, priority, key)
      varz[:queue_length] = @queue.size
    end

    def running_count(app)
      counts = {}

      app.versions.each do |version, version_entry|
        counts[version] =
          version_entry["instances"].count do |_, instance|
            instance["state"] == RUNNING
          end
      end

      counts
    end
  end
end
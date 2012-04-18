module HealthManager
  class Nudger
    include HealthManager::Common

    def initialize( config={} )
      @config = config
      @queue = VCAP::PrioritySet.new
      @queue_batch_size = get_param_from_config_or_constant(:queue_batch_size, @config)
    end

    def deque_batch_of_requests
      @queue_batch_size.times do |i|
        break if @queue.empty?
        message = encode_json(@queue.remove)


        if ['false','mixed'].include? ENV[HM_SHADOW]
          publish_request_message(message)
        else
          logger.info("nudger: SHADOW: cloudcontrollers.hm.requests: #{message}")
        end
      end
    end

    def publish_request_message(message)
      logger.info("nudger: NATS.publish: cloudcontrollers.hm.requests: #{message}")
      NATS.publish('cloudcontrollers.hm.requests', message)
    end

    def start_missing_instances(app, priority)
      start_instances(app, app.missing_indices, priority)
    end

    def start_instance(app, index, priority)
      start_instances(app, [index], priority)
    end

    def start_instances(app, indicies, priority)
      logger.debug { "nudger: starting instances #{indicies} for #{app.id} priority: #{priority}" }
      message = {
        :droplet => app.id,
        :op => :START,
        :last_updated => app.last_updated,
        :version => app.live_version,
        :indices => indicies
      }
      queue(message, priority)
    end

    def stop_instances_immediately(app, instances_and_reasons)

      publish_request_message(make_stop_message(app, instances_and_reasons.map {|instance, reason| instance }))
    end

    def stop_instance(app, instance, priority)
      logger.debug { "nudger: stopping instance: app: #{app.id} instance: #{instance}" }
      queue(make_stop_message(app,instance),priority)
    end

    def make_stop_message(app, instance)
      {
        :droplet => app.id,
        :op => :STOP,
        :last_updated => app.last_updated,
        :instances => instance
      }
    end

    private
    def queue(message, priority)
      logger.debug { "nudger: queueing: #{message}, #{priority}" }
      priority ||= NORMAL_PRIORITY
      key = message.clone.delete(:last_updated)
      @queue.insert(message, priority, key)
      varz.set(:queue_length, @queue.size)
    end
  end

  class Shadower
    include HealthManager::Common

    def initialize(config = {})
      @received = {}
    end

    def subscribe
      subscribe_on('healthmanager.start')
      subscribe_on('cloudcontrollers.hm.requests')

      ['status','health'].each do |m|
        subj = "healthmanager.#{m}"
        logger.info("shadower: subscribing: #{subj}")
        NATS.subscribe(subj) do |message, reply|
          logger.info("shadower: received: #{subj}: #{message}")
          subscribe_on(reply, "#{subj}.reply")
        end
      end
    end

    def subscribe_on(subj, topic = nil)
      topic ||= subj
      logger.info("shadower: subscribing: #{subj}/#{topic}")

      #"subjet" is NATS subject. "Topic" is the label for the bin.
      #they are the same except for NATS "reply-to" subjects.

      NATS.subscribe(subj) do |message|
        logger.info{"shadower: received: #{subj}/#{topic}: #{message}"}

        @received[topic] ||= []
        @received[topic] << message
        if @received[topic].size > 1000
          @received[topic] = @received[topic][500..-1]
        end

        NATS.unsubscribe(subj) if subj!=topic #unsubscribe from "reply-to" subjects
      end
    end
  end
end

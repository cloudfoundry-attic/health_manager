require 'em-http'

module HealthManager
  class DesiredState
    include HealthManager::Common
    attr_reader :varz

    def initialize(config, varz, droplet_registry)
      @config = config
      @varz = varz
      @error_count = 0
      @connected = false
      @droplet_registry = droplet_registry
      @droplet_ids = []
    end

    def update(&block)
      @droplet_ids = []
      process_next_batch({}, &block)
    end

    def update_user_counts
      with_credentials do |user, password|
        options = {
          :head => { 'authorization' => [user, password] },
          :query => { 'model' => 'user' }
        }
        http = EM::HttpRequest.new(counts_url).get(options)
        http.callback do
          if http.response_header.status != 200
            logger.error("bulk: request problem. Response: #{http.response_header} #{http.response}")
            @connected = false
            reset_credentials
            next
          end
          @connected = true

          response = parse_json(http.response) || {}
          logger.debug { "bulk: user counts received: #{response}" }

          counts = response['counts'] || {}
          varz[:total_users] = (counts['user'] || 0).to_i
        end

        http.errback do
          @connected = false
          logger.error("bulk: error: talking to bulk API at #{counts_url}")
          reset_credentials
        end
      end
    end

    def reset_credentials
      @user = @password = nil #ensure re-acquisition of credentials
    end

    def process_next_batch(bulk_token, &block)
      with_credentials do |user, password|
        options = {
          :head => { 'authorization' => [user, password] },
          :query => {
            'batch_size' => batch_size,
            'bulk_token' => encode_json(bulk_token)
          },
        }

        http = EM::HttpRequest.new(app_url).get(options)
        http.callback do
          @error_count = 0 # reset after a successful request

          if http.response_header.status != 200
            logger.error("bulk: request problem. Response status: #{http.response_header.status}")
            @connected = false
            next
          end
          @connected = true

          response = parse_json(http.response)
          bulk_token = response['bulk_token']
          batch = response['results']

          if batch.nil? || batch.empty?
            @droplet_registry.delete_if { |id, _| !@droplet_ids.include?(id.to_s) }
            @droplet_ids = []
            varz.publish_desired_stats
            logger.info("bulk: done. Loop duration: #{varz[:bulk_update_loop_duration]}")
            next
          end

          logger.debug { "bulk: batch of size #{batch.size} received" }

          batch.each do |app_id, droplet|
            update_desired_stats_for_droplet(droplet)
            @droplet_registry.get(app_id).set_desired_state(droplet)
            @droplet_ids << app_id.to_s
            block.call(app_id.to_s, droplet) if block
          end
          process_next_batch(bulk_token, &block)
        end

        http.errback do
          logger.warn ([ "problem talking to bulk API at #{app_url}",
                        "bulk_token: #{bulk_token}",
                        "status: #{http.response_header.status}",
                        "error count: #{@error_count}"
                      ].join(", "))

          @error_count += 1

          if @error_count < MAX_BULK_ERROR_COUNT
            logger.info("Retrying bulk request, bulk_token: #{bulk_token}")
            process_next_batch(bulk_token, &block)
          else
            logger.error("Too many consecutive bulk API errors.")
            @connected = false
            reset_credentials
          end
        end
      end
    end

    def host
      (@config['bulk_api'] && @config['bulk_api']['host']) || "api.vcap.me"
    end

    def batch_size
      (@config['bulk_api'] && @config['bulk_api']['batch_size']) || "500"
    end

    def bulk_url
      url = "#{host}/bulk"
      url = "http://#{url}" unless url =~ /^https?:/
      url
    end

    def app_url
      "#{bulk_url}/apps"
    end

    def counts_url
      "#{bulk_url}/counts"
    end

    def with_credentials
      if @user && @password
        yield @user, @password
      else
        logger.info("bulk: requesting API credentials over NATS...")
        sid = NATS.request("cloudcontroller.bulk.credentials.#{cc_partition}", nil, :max => 1) do |response|
          logger.info("bulk: API credentials received.")
          auth =  parse_json(response)
          @user = auth[:user] || auth['user']
          @password = auth[:password] || auth['password']
          yield @user, @password
        end

        NATS.timeout(sid, get_param_from_config_or_default(:nats_request_timeout, @config)) do
          logger.error("bulk: NATS timeout getting bulk api credentials. Request ignored.")
        end
      end
    end

    def available?
      @connected
    end

    private

    def update_desired_stats_for_droplet(droplet_hash)
      varz[:total][:apps] += 1
      varz[:total][:instances] += droplet_hash['instances']
      varz[:total][:memory] += droplet_hash['memory'] * droplet_hash['instances']

      if droplet_hash['state'] == STARTED
        varz[:total][:started_apps] += 1
        varz[:total][:started_instances] += droplet_hash['instances']
        varz[:total][:started_memory] += droplet_hash['memory'] * droplet_hash['instances']
      end
    end
  end
end

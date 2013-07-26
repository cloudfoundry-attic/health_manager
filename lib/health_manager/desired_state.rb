require 'em-http'
require 'set'

module HealthManager
  class DesiredState
    include HealthManager::Common
    attr_reader :varz

    def initialize(varz, droplet_registry, message_bus)
      @varz = varz
      @error_count = 0
      @connected = false
      @droplet_registry = droplet_registry
      @message_bus = message_bus
    end

    def update(&block)
      process_next_batch({}, Time.now, &block)
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

    def process_next_batch(bulk_token, start_time, &block)
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
            logger.error("hm.desired-state.error",
                         response_status: http.response_header.status)
            @connected = false
            next
          end

          @connected = true

          response = parse_json(http.response)
          bulk_token = response['bulk_token']
          batch = response['results']

          if batch.nil? || batch.empty?
            duration = Time.now - start_time

            varz.publish_desired_stats

            logger.info "hm.desired-state.bulk-update-done", duration: duration

            next
          end

          logger.debug "hm.desired-state.bulk-update-batch-received", size: batch.size

          batch.each do |app_id, droplet|
            update_desired_stats_for_droplet(droplet)
            @droplet_registry.get(app_id).set_desired_state(droplet)
            block.call(app_id.to_s, droplet) if block
          end

          process_next_batch(bulk_token, start_time, &block)
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
            process_next_batch(bulk_token, start_time, &block)
          else
            logger.error("Too many consecutive bulk API errors.")
            @connected = false
            reset_credentials
          end
        end
      end
    end

    def host
      HealthManager::Config.bulk_api_url
    end

    def batch_size
      HealthManager::Config.bulk_api_batch_size
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
        logger.info("bulk: requesting API credentials over message bus...")
        @message_bus.request("cloudcontroller.bulk.credentials.#{cc_partition}", nil, max: 1, timeout: HealthManager::Config.interval(:bulk_credentials_timeout)) do |response|
          if response[:timeout]
            logger.error("bulk: message bus timeout getting bulk api credentials. Request ignored.")
          else
            logger.info("bulk: API credentials received.")
            @user = response[:user] || response['user']
            @password = response[:password] || response['password']
            yield @user, @password
          end
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

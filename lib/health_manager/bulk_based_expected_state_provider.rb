require 'em-http'

module HealthManager
  #this implementation will use the REST(ish) BulkAPI to
  #interrogate the CloudController on the expected state of the apps
  #the API should allow for non-blocking operation
  class BulkBasedExpectedStateProvider < ExpectedStateProvider

    def each_droplet(&block)
      process_next_batch({}, &block)
    end

    def initialize(config)
      @error_count = 0
      super(config)
    end

    def set_expected_state(known, expected)
      logger.debug2 { "bulk: #set_expected_state: known: #{known.inspect} expected: #{expected.inspect}" }

      known.set_expected_state(
                               :num_instances => expected['instances'],
                               :state         => expected['state'],
                               :live_version  => expected['version'],
                               :package_state => expected['package_state'],
                               :last_updated  => parse_utc(expected['updated_at']))
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
            reset_credentials
            next
          end

          response = parse_json(http.response) || {}
          logger.debug { "bulk: user counts received: #{response}" }

          counts = response['counts'] || {}
          varz.set(:total_users, (counts['user'] || 0).to_i)
        end

        http.errback do
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
            varz.release_expected_stats
            next
          end

          response = parse_json(http.response)
          bulk_token = response['bulk_token']
          batch = response['results']

          if batch.nil? || batch.empty?
            varz.publish_expected_stats
            logger.info("bulk: done. Loop duration: #{varz.get(:bulk_update_loop_duration)}")
            next
          end

          logger.debug { "bulk: batch of size #{batch.size} received" }

          batch.each do |app_id, droplet|
            varz.update_expected_stats_for_droplet(droplet)
            block.call(app_id.to_s, droplet)
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
            varz.release_expected_stats
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
      url = "http://"+url unless url.start_with?("http://")
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

        NATS.timeout(sid,
                     get_param_from_config_or_default(:nats_request_timeout, @config)) do
          logger.error("bulk: NATS timeout getting bulk api credentials. Request ignored.")
          varz.release_expected_stats if varz.expected_stats_held?
        end
      end
    end
  end
end

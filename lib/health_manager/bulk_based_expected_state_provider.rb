require 'em-http'

module HealthManager
  #this implementation will use the REST(ish) BulkAPI to
  #interrogate the CloudController on the expected state of the apps
  #the API should allow for non-blocking operation
  class BulkBasedExpectedStateProvider < ExpectedStateProvider

    def each_droplet(&block)
      process_next_batch({}, &block)
    end

    def set_expected_state(known, expected)
      logger.debug2 { "bulk: #set_expected_state: known: #{known.inspect} expected: #{expected.inspect}" }

      known.set_expected_state(
                               :num_instances => expected['instances'],
                               :state         => expected['state'],
                               :live_version  => expected['version'],
                               :framework     => expected['framework'],
                               :runtime       => expected['runtime'],
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
            next
          end

          response = parse_json(http.response) || {}
          logger.debug { "bulk: user counts received: #{response}" }

          counts = response['counts'] || {}
          varz.set(:total_users, (counts['user'] || 0).to_i)
        end

        http.errback do
          logger.error("bulk: error: talking to bulk API at #{counts_url}")
          @user = @password = nil #ensure re-acquisition of credentials
        end
      end
    end

    private

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
          if http.response_header.status != 200
            logger.error("bulk: request problem. Response: #{http.response_header} #{http.response}")
            varz.release_expected_stats
            next
          end

          response = parse_json(http.response)
          bulk_token = response['bulk_token']
          batch = response['results']

          if batch.nil? || batch.empty?
            varz.publish_expected_stats
            logger.info("bulk: done")
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
          logger.error("problem talking to bulk API at #{app_url}")
          varz.release_expected_stats
          @user = @password = nil #ensure re-acquisition of credentials
        end
      end
    end

    def host
      (@config['bulk_api'] && @config['bulk_api']['host']) || "api.vcap.me"
    end

    def batch_size
      (@config['bulk_api'] && @config['bulk_api']['batch_size']) || "50"
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
          varz.release_expected_stats
        end
      end
    end
  end
end

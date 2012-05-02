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
      logger.debug { "bulk: #set_expected_state: known: #{known.inspect} expected: #{expected.inspect}" }

      known.set_expected_state(
                               expected['instances'],
                               expected['state'],
                               "#{expected['staged_package_hash']}-#{expected['run_count']}",
                               expected['framework'],
                               expected['runtime'],
                               parse_utc(expected['updated_at']))
    end

    private

    def process_next_batch(bulk_token, &block)
      with_credentials do |user, password|
        options = {
          :head => { 'authorization' => [user, password] },
          :query => {
            'batch_size' => batch_size,
            'bulk_token' => bulk_token.to_json
          },
        }
        http = EM::HttpRequest.new(app_url).get(options)
        http.callback do
          if http.response_header.status != 200
            logger.error("bulk: request problem. Response: #{http.response_header} #{http.response}")
            release_varz
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
            block.call(app_id, droplet)
          end
          process_next_batch(bulk_token, &block)
        end

        http.errback do
          logger.error("problem talking to bulk API at #{app_url}")
          release_varz
          @user = @password = nil #ensure re-acquisition of credentials
        end
      end
    end

    def release_varz
      varz.reset_expected_stats
      varz.publish_expected_stats
    end

    def host
      (@config['bulk'] && @config['bulk']['host']) || "api.vcap.me"
    end

    def batch_size
      (@config['bulk'] && @config['bulk']['batch_size']) || "50"
    end

    def app_url
      url = "#{host}/bulk/apps"
      url = "http://"+url unless url.start_with?("http://")
      url
    end

    def with_credentials
      if @user && @password
        yield @user, @password
      else
        logger.info("bulk: requesting API credentials over NATS...")
        sid = NATS.request('cloudcontroller.bulk.credentials') do |response|
          logger.info("bulk: API credentials received.")
          auth =  parse_json(response)
          @user = auth[:user] || auth['user']
          @password = auth[:password] || auth['password']
          yield @user, @password
        end

        NATS.timeout(sid,
                     get_param_from_config_or_default(:nats_request_timeout, @config)) do
          logger.error("bulk: NATS timeout getting bulk api credentials. Request ignored.")
          release_varz
        end
      end
    end
  end
end

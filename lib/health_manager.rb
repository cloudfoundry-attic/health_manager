# HealthManager 2.0. (c) 2011-2012 VMware, Inc.
$:.unshift(File.dirname(__FILE__))

require 'yaml'
require 'yajl'
require 'optparse'
require 'time'
require 'nats/client'
require 'steno'

require 'vcap/common'
require 'vcap/component'
require 'vcap/priority_queue'

require 'health_manager/constants'
require 'health_manager/common'
require 'health_manager/app_state'
require 'health_manager/app_state_provider'
require 'health_manager/nats_based_known_state_provider'
require 'health_manager/bulk_based_expected_state_provider'
require 'health_manager/scheduler'
require 'health_manager/nudger'
require 'health_manager/harmonizer'
require 'health_manager/varz'
require 'health_manager/reporter'
require 'health_manager/shadower'

module HealthManager
  class Manager
    include HealthManager::Common

    attr_reader :varz, :known_state_provider, :expected_state_provider, :reporter, :nudger, :publisher, :harmonizer

    def initialize(config = {})
      @config = config
      logger.info("HealthManager: initializing")

      @varz = Varz.new(@config)

      if should_shadow?
        @publisher = @shadower = Shadower.new(@config)
      else
        @publisher = NATS
      end

      @scheduler = Scheduler.new(@config)
      @known_state_provider = NatsBasedKnownStateProvider.new(@config, @varz)
      @expected_state_provider = BulkBasedExpectedStateProvider.new(@config, @varz)
      @reporter = Reporter.new(@config, @varz, @known_state_provider, @publisher)
      @nudger = Nudger.new(@config, @varz, @publisher)
      @harmonizer = Harmonizer.new(@config, @varz, @nudger, @scheduler, @known_state_provider, @expected_state_provider)
    end

    def register_as_vcap_component
      logger.info("registering VCAP component")
      logger.debug("config: #{sanitized_config}")

      status_config = @config['status'] || {}
      VCAP::Component.register(:type => 'HealthManager',
                               :host => VCAP.local_ip(@config['local_route']),
                               :index => @config['index'] || 0,
                               :config => sanitized_config,
                               :nats => @publisher,
                               :port => status_config['port'],
                               :user => status_config['user'],
                               :password => status_config['password'],
                               :logger => logger
      )
    end

    def start
      logger.info("starting...")

      EM.epoll
      NATS.on_error do
        logger.warn("can't connect to NATS")
      end

      NATS.start(:uri => get_nats_uri, :max_reconnect_attempts => Float::INFINITY) do
        @reporter.prepare
        @harmonizer.prepare
        @expected_state_provider.start
        @known_state_provider.start

        if should_shadow?
          logger.info("starting Shadower")
          @shadower.subscribe_to_all
        end

        register_as_vcap_component
        @scheduler.start #blocking call
      end
    end

    def sanitized_config
      config = @config.dup
      config.delete(:health_manager_component_registry)
      config
    end

    def shutdown
      logger.info("shutting down...")
      NATS.stop { EM.stop }
      logger.info("...good bye.")
    end

    def get_nats_uri
      ENV[NATS_URI] || @config['mbus']
    end

    def self.now
      Time.now.to_i
    end
  end
end

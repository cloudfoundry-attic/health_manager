# HealthManager 2.0. (c) 2011-2012 VMware, Inc.
$:.unshift(File.dirname(__FILE__))

require 'yaml'
require 'yajl'
require 'optparse'
require 'time'
require 'nats/client'

require 'vcap/common'
require 'vcap/component'
require 'vcap/logging'
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
require 'health_manager/varz_common'
require 'health_manager/varz'
require 'health_manager/reporter'
require 'health_manager/shadower'

module HealthManager
  class Manager
    include HealthManager::Common

    attr_reader :scheduler
    attr_reader :known_state_provider
    attr_reader :expected_state_provider

    def initialize(config={})
      @config = config
      logger.info("HealthManager: initializing")

      @varz = Varz.new(@config)
      @reporter = Reporter.new(@config)
      @scheduler = Scheduler.new(@config)
      @known_state_provider = AppStateProvider.get_known_state_provider(@config)
      @expected_state_provider = AppStateProvider.get_expected_state_provider(@config)
      @nudger = Nudger.new(@config)
      @harmonizer = Harmonizer.new(@config)

      if should_shadow?
        @publisher = @shadower = Shadower.new(@config)
      else
        @publisher = NATS
      end

      register_hm_components
    end

    def register_as_vcap_component
      logger.info("registering VCAP component")
      logger.debug("config: #{sanitized_config}")

      status_config = @config['status'] || {}
      VCAP::Component.register(:type => 'HealthManager',
                               :host => VCAP.local_ip(@config['local_route']),
                               :index => @config['index'],
                               :config => sanitized_config,
                               :port => status_config['port'],
                               :user => status_config['user'],
                               :password => status_config['password'])
    end

    def create_pid_file
      @pid_file = @config['pid']
      VCAP::PidFile.new(@pid_file) if @pid_file
    end

    def start
      logger.info("starting...")

      EM.epoll
      NATS.start :uri => get_nats_uri do
        @varz.prepare
        @reporter.prepare
        @harmonizer.prepare
        @expected_state_provider.start
        @known_state_provider.start

        if should_shadow?
          logger.info("starting Shadower")
          @shadower.subscribe
        end

        register_as_vcap_component
        create_pid_file if @config['pid']

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

# HealthManager 2.0. (c) 2011-2012 VMware, Inc.
$:.unshift(File.dirname(__FILE__))

require 'yaml'
require 'yajl'
require 'optparse'
require 'time'
require 'cf_message_bus/message_bus'
require 'steno'

require 'vcap/common'
require 'vcap/component'
require 'vcap/priority_queue'

require 'health_manager/constants'
require 'health_manager/common'
require 'health_manager/config'
require 'health_manager/droplet'
require 'health_manager/actual_state'
require 'health_manager/desired_state'
require 'health_manager/droplet_registry'
require 'health_manager/scheduler'
require 'health_manager/nudger'
require 'health_manager/harmonizer'
require 'health_manager/varz'
require 'health_manager/reporter'
require 'health_manager/fake_scheduler'

module HealthManager
  class Manager
    include HealthManager::Common

    attr_reader :varz, :actual_state, :desired_state, :droplet_registry, :reporter, :nudger, :publisher, :harmonizer

    def initialize(config = {})
      HealthManager::Config.load(config)

      @log_counter = Steno::Sink::Counter.new

      setup_logging(HealthManager::Config.logging_config)

      logger.info("HealthManager: initializing with config: #{config}")

      @varz = Varz.new
    end

    def register_as_vcap_component(message_bus)
      logger.info("registering VCAP component")
      logger.debug("config: #{sanitized_config}")

      status_config = HealthManager::Config.get_param(:status) || {}
      VCAP::Component.register(:type => 'HealthManager',
                               :host => VCAP.local_ip(HealthManager::Config.config[:local_route]),
                               :index => HealthManager::Config.config[:index] || 0,
                               :config => sanitized_config,
                               :nats => message_bus,
                               :port => status_config[:port],
                               :user => status_config[:user],
                               :password => status_config[:password],
                               :logger => logger,
                               :log_counter => @log_counter
      )
    end

    def setup_logging(logging_config)
      steno_config = Steno::Config.to_config_hash(logging_config)
      steno_config[:context] = Steno::Context::ThreadLocal.new
      config = Steno::Config.new(steno_config)
      config.sinks << @log_counter
      Steno.init(config)
    end

    def setup_components(message_bus)
      if HealthManager::Config.black_box_test_mode?
        @scheduler = FakeScheduler.new(message_bus)
        @@scheduler = @scheduler
      else
        @scheduler = Scheduler.new
      end
      @droplet_registry = DropletRegistry.new
      @actual_state = ActualState.new(@varz, @droplet_registry, message_bus)
      @desired_state = DesiredState.new(@varz, @droplet_registry, message_bus)
      @nudger = Nudger.new(@varz, message_bus)
      @harmonizer = Harmonizer.new(@varz, @nudger, @scheduler, @actual_state, @desired_state, @droplet_registry)
      @reporter = Reporter.new(@varz, @droplet_registry, message_bus)
    end

    def start
      logger.info("starting...")

      EM.epoll
      EM.run do
        message_bus = CfMessageBus::MessageBus.new(uri: message_bus_uri, logger: logger)
        setup_components(message_bus)

        @reporter.prepare
        @harmonizer.prepare
        @actual_state.start

        register_as_vcap_component(message_bus)
        @scheduler.start #blocking call
      end
    end

    def sanitized_config
      sanitized_config = HealthManager::Config.config.dup
      sanitized_config.delete(:health_manager_component_registry)
      sanitized_config
    end

    def shutdown
      logger.info("shutting down...")
      EM.stop
      logger.info("...good bye.")
    end

    def message_bus_uri
      ENV[MBUS_URI] || HealthManager::Config.mbus_url
    end

    def self.now
      if HealthManager::Config.black_box_test_mode?
        @@scheduler.now
      else
        Time.now.to_i
      end
    end
  end
end

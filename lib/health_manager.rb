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

module HealthManager
  class Manager
    include HealthManager::Common
    #primarily for testing
    attr_reader :scheduler
    attr_reader :known_state_provider
    attr_reader :expected_state_provider

    def initialize(config={})
      args = parse_args
      @config = read_config_from_file(args[:config_file]).merge(config)

      @logging_config = @config['logging']
      @logging_config = {'level' => ENV['LOG_LEVEL']} if ENV['LOG_LEVEL'] #ENV override
      @logging_config ||= {'level' => 'info'} #fallback value

      VCAP::Logging.setup_from_config(@logging_config)

      logger.info("HealthManager: initializing")

      @varz = Varz.new(@config)
      @reporter = Reporter.new(@config)
      @scheduler = Scheduler.new(@config)
      @known_state_provider = AppStateProvider.get_known_state_provider(@config)
      @expected_state_provider = AppStateProvider.get_expected_state_provider(@config)
      @nudger = Nudger.new(@config)
      @harmonizer = Harmonizer.new(@config)

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
      begin
        FileUtils.mkdir_p(File.dirname(@pid_file))
      rescue => e
        logger.fatal("Can't create pid directory, exiting: #{e}")
      end
      File.open(@pid_file, 'wb') { |f| f.puts "#{Process.pid}" }
      logger.debug("pid file written: #{@pid_file}")
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

        unless ENV[HM_SHADOW]=='false'
          logger.info("creating Shadower")
          @shadower = Shadower.new(@config)
          @shadower.subscribe
        end

        register_as_vcap_component
        create_pid_file if @config['pid']

        @scheduler.start #blocking call
      end
    end

    def shutdown
      logger.info("shutting down...")
      NATS.stop { EM.stop }
      logger.info("...good bye.")
    end

    def read_config_from_file(config_file)
      config_path = ENV['CLOUD_FOUNDRY_CONFIG_PATH'] || File.join(File.dirname(__FILE__),'../config')
      config_file ||= File.join(config_path, 'health_manager.yml')
      begin
        config = YAML.load_file(config_file)
      rescue => e
        $stderr.puts "Could not read configuration file #{config_file}: #{e}"
        exit 1
      end
      config
    end

    def get_nats_uri
      ENV[NATS_URI] || @config['mbus']
    end

    def self.now
      Time.now.to_i
    end
  end
end

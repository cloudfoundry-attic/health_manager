module HealthManager::Common

  def interval(name)
    get_interval_from_config_or_constant(name, @config)
  end

  def get_interval_from_config_or_constant(name, config)
    intervals = config[:intervals] || config['intervals'] || {}
    get_param_from_config_or_constant(name,intervals)
  end

  def get_param_from_config_or_constant(name, config)
    value = config[name] || config[name.to_sym] || config[name.to_s]
    unless value
      const_name = name.to_s.upcase
      if HealthManager.const_defined?( const_name )
        value = HealthManager.const_get( const_name )
      end
    end
    raise ArgumentError, "undefined parameter #{name}" unless value
    logger.debug("config: #{name}: #{value}")
    value
  end

  HealthManager::COMPONENTS.each do |name|
    define_method name do
      find_hm_component(name)
    end
  end

  def register_hm_components
    HealthManager::COMPONENTS.each { |name|
      component = self.instance_variable_get("@#{name}")
      register_hm_component(name, component)
    }
  end

  def register_hm_component(name, component)
    hm_registry[name] = component
  end

  def find_hm_component(name)
    unless component = hm_registry[name]
      raise ArgumentError, "component #{name} can't be found in the registry #{@config}"
    end
    component
  end

  def hm_registry
    @config[:health_manager_component_registry] ||= {}
  end

  def sanitized_config
    config = @config.dup
    config.delete(:health_manager_component_registry)
    config
  end

  def parse_args
    results = {}
    options = OptionParser.new do |opts|
      opts.banner = "Usage: health_manager [OPTIONS]"
      opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
        results[:config_file] = opt
      end

      opts.on("-h", "--help", "Help") do
        puts opts
        exit
      end
    end
    options.parse!(ARGV.dup)
    results
  end

  def read_config_from_file(config_file)
    config = {}
    begin
      config = File.open(config_file) do |f|
        YAML.load(f)
      end
    rescue => e
      puts "Could not read configuration file: #{e}"
      exit
    end
    config
  end

  def logger
    @logger ||= get_logger
  end

  def get_logger
    VCAP::Logging.logger('healthmanager')
  end

  def encode_json(obj={})
    Yajl::Encoder.encode(obj)
  end

  def parse_json(string='{}')
    Yajl::Parser.parse(string)
  end

  def timestamp_fresher_than?(timestamp, age)
    timestamp > 0 && now - timestamp < age
  end

  def timestamp_older_than?(timestamp, age)
    timestamp > 0 && now - timestamp > age
  end

  def now
    ::HealthManager::Manager.now
  end

  def parse_utc(time)
    Time.parse(time).to_i
  end
end

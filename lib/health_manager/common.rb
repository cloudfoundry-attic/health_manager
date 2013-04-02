module HealthManager::Common

  def interval(name)
    get_interval_from_config_or_default(name, @config)
  end

  def cc_partition
    @cc_partition ||= get_param_from_config_or_default(:cc_partition, @config)
  end

  def get_interval_from_config_or_default(name, config)
    intervals = config[:intervals] || config['intervals'] || {}
    get_param_from_config_or_default(name, intervals)
  end

  def get_param_from_config_or_default(name, config)
    value = config[name] ||
      config[name.to_sym] ||
      config[name.to_s] ||
      HealthManager::DEFAULTS[name.to_sym]

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
    HealthManager::COMPONENTS.each do |name|
      component = self.instance_variable_get("@#{name}")
      register_hm_component(name, component)
    end
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

  def should_shadow?
    #do NOT shadow by default
    ENV[HealthManager::HM_SHADOW] == 'true' ||
      get_param_from_config_or_default('shadow_mode',@config) == 'enable'
  end

  def logger
    @logger ||= get_logger
  end

  def get_logger
    Steno.logger("hm")
  end

  def encode_json(obj = {})
    Yajl::Encoder.encode(obj)
  end

  def parse_json(string = '{}')
    Yajl::Parser.parse(string)
  end

  def timestamp_fresher_than?(timestamp, age)
    timestamp > 0 && now - timestamp < age
  end

  def timestamp_older_than?(timestamp, age)
    timestamp > 0 && (now - timestamp) > age
  end

  def now
    ::HealthManager::Manager.now
  end

  def parse_utc(time)
    Time.parse(time).to_i
  end
end

module HealthManager::Common
  def interval(name)
    HealthManager::Config.interval(name)
  end

  def cc_partition
    @cc_partition ||= HealthManager::Config.get_param(:cc_partition)
  end

  def logger
    @logger ||= get_logger
  end

  def get_logger
    Steno.logger("hm")
  end

  def encode_json(obj)
    Yajl::Encoder.encode(obj)
  end

  def parse_json(string)
    Yajl::Parser.parse(string)
  end

  def now
    ::HealthManager::Manager.now
  end
end

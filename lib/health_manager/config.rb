module HealthManager
  class Config

    # Just gives back the raw hash
    def self.config
      @config
    end

    def self.load(config)
      @config = symbolize_keys(config)
      @config[:logging] ||= {}
      @config[:logging][:level] = ENV["LOG_LEVEL"] if ENV["LOG_LEVEL"]
      @config[:logging][:level] ||= "info"

      @config[:status] ||= {}
    end

    def self.black_box_test_mode?
      @config[:black_box_test_mode] != nil
    end

    def self.get_param(name, local_config = @config)
      value = local_config[name.to_sym] ||
        HealthManager::DEFAULTS[name.to_sym]

      raise ArgumentError, "undefined parameter #{name}" unless value
      #logger.debug("config: #{name}: #{value}")
      value
    end

    def self.interval(name)
      intervals = get_param(:intervals)
      value = intervals[name.to_sym] || HealthManager::DEFAULTS[:intervals][name.to_sym]

      raise ArgumentError, "undefined parameter #{name}" unless value
      value
    end

    def self.bulk_api_url
      get_param(:host, get_param(:bulk_api))
    end

    def self.bulk_api_batch_size
      bulk_api_config = @config[:bulk_api] || {}
      bulk_api_config[:batch_size] || "500"
    end

    def self.logging_config
      @config[:logging]
    end

    def self.mbus_url
      get_param(:mbus)
    end

    def self.status_config
      @config[:status]
    end

    private

    def self.symbolize_keys(hash)
      return hash unless hash.is_a? Hash
      Hash[
        hash.each_pair.map do |k, v|
            [k.to_sym, symbolize_keys(v)]
        end
      ]
    end
  end
end


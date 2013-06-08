require 'set'

module HealthManager
  class AppStateProvider
    include HealthManager::Common

    def initialize(config, varz)
      @config = config
      @droplets = {} # hashes droplet_id => AppState instance
      @cur_droplet_index = 0
      @ids = []
      @varz = varz
    end

    attr_reader :droplets, :varz

    def start; end

    # these methods have to do with threading and quantization
    def rewind
      @cur_droplet_index = 0
      @ids = @droplets.keys
    end

    def next_droplet
      # The @droplets hash may have undergone modifications while
      # we're iterating. New items that are added will not be seen
      # until #rewind is called again. Deleted droplets will be
      # skipped over.

      droplet = nil # nil value indicates the end of the collection

      # skip over garbage-collected droplets
      while (droplet = @droplets[@ids[@cur_droplet_index]]).nil? && @cur_droplet_index < @ids.size
        @cur_droplet_index += 1
      end

      @cur_droplet_index += 1
      droplet
    end

    def has_droplet?(id)
      @droplets.has_key?(id.to_s)
    end

    def get_droplet(id)
      id = id.to_s
      @droplets[id] ||= AppState.new(id)
    end

    def get_state(id)
      get_droplet(id.to_s).state
    end
  end

  # "abstract" provider of expected state. Primarily for documenting the API
  class ExpectedStateProvider < AppStateProvider
    def set_expected_state(known, expected)
      raise 'Not Implemented' # should be implemented by the concrete class
    end
  end
end

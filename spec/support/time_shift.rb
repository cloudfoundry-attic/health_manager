# Overrides HealthManager::Manager#now for the purposes of time-based
# testing, also providing helper methods

module HealthManager
  module Common

    # forwards call from Common-including *object* to the Manager
    # *class*. All hm components include Common.
    def freeze_time
      ::HealthManager::Manager.freeze_time
    end
    def unfreeze_time
      ::HealthManager::Manager.unfreeze_time
    end
    def move_time(delta)
      ::HealthManager::Manager.move_time(delta)
    end
  end

  # Forwarding to the single instance ensures we're using the same
  # value of @now across the board
  class Manager
    def self.now
      @now || Time.now.to_i
    end

    def self.freeze_time
      @now ||= now
    end

    def self.unfreeze_time
      @now = nil
    end

    def self.move_time(delta)
      @now += delta
    end
  end
end


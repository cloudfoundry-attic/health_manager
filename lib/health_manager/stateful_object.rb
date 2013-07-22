module HealthManager
  module StatefulObject
    def running?
      state == 'RUNNING'
    end

    def starting_or_running?
      %w[STARTING RUNNING].include?(state)
    end

    def crashed?
      state == 'CRASHED'
    end

    def flapping?
      state == 'FLAPPING'
    end

    def down?
      state == 'DOWN'
    end
  end
end
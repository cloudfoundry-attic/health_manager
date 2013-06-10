module HealthManager
  class DropletRegistry < Hash
    def get(id)
      self[id.to_s] ||= AppState.new(id)
    end
  end
end
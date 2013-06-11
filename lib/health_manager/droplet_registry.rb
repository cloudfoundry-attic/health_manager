module HealthManager
  class DropletRegistry < Hash
    def get(id)
      self[id.to_s] ||= Droplet.new(id)
    end
  end
end
require 'spec_helper'

describe HealthManager::DropletRegistry do
  let(:droplet_registry) { HealthManager::DropletRegistry.new }
  let(:droplet) { HealthManager::Droplet.new(2) }

  describe "#get" do
    context "when droplet is in registry" do
      before { droplet_registry[droplet.id] = droplet }
      it "return a droplet" do
        expect(droplet_registry.get(droplet.id)).to eql(droplet)
      end
    end

    context "when droplet is NOT in registry" do
      it "creates a droplet" do
        expect(droplet_registry.get(99)).to be_an_instance_of(HealthManager::Droplet)
      end
    end
  end
end
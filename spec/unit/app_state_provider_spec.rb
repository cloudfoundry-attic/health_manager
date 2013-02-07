require 'spec_helper'

describe HealthManager do

  describe "AppStateProvider" do
    describe '#get_known_state_provider' do
      it 'should return NATS-based provider by default' do
        HealthManager::AppStateProvider.get_known_state_provider.
          should be_an_instance_of(HealthManager::NatsBasedKnownStateProvider)
      end
    end

    describe '#get_expected_state_provider' do
      it 'should return bulk-API-based provider by default' do
        HealthManager::AppStateProvider.get_expected_state_provider.
          should be_an_instance_of(HealthManager::BulkBasedExpectedStateProvider)
      end
    end
  end
end

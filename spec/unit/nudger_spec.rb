require 'spec_helper.rb'

describe HealthManager do
  Manager = HealthManager::Manager
  Nudger = HealthManager::Nudger

  before(:each) do
    @m = Manager.new
    @m.varz.prepare
  end

  describe Nudger do
    it 'should be able to start app instance' do
      n = @m.nudger
      NATS.should_receive(:publish).with('cloudcontrollers.hm.requests', match(/"op":"START"/)).once
      n.start_instance(AppState.new(1), 0, 0)
      set_env(::HealthManager::HM_SHADOW, 'false')
      n.deque_batch_of_requests
      restore_env(::HealthManager::HM_SHADOW)
    end

    it 'should be able to stop app instance' do
      n = @m.nudger
      NATS.should_receive(:publish).with('cloudcontrollers.hm.requests', match(/"op":"STOP"/)).once
      n.stop_instance(AppState.new(1), 0, 0)
      set_env(::HealthManager::HM_SHADOW, 'false')
      n.deque_batch_of_requests
      restore_env(::HealthManager::HM_SHADOW)
    end
  end
end

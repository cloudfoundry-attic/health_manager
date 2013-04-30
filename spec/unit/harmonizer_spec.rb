require "spec_helper"

module HealthManager
  describe Harmonizer do
    describe "when app is considered to be an extra app" do
      let(:nudger) { mock }
      let(:expected_state_provider) { mock }
      let(:app) do
        app, _ = make_app(:num_instances => 1)
        heartbeats = make_heartbeat([app], :app_live_version => "version-1")
        app.process_heartbeat(heartbeats["droplets"][0])
        heartbeats = make_heartbeat([app], :app_live_version => "version-2")
        app.process_heartbeat(heartbeats["droplets"][0])
        app
      end

      subject do
        Harmonizer.new({
          :health_manager_component_registry => {:nudger => nudger},
        }, {}, nudger, nil, nil, expected_state_provider)
      end

      it "stops all instances of the app" do
        nudger
          .should_receive(:stop_instances_immediately)
          .with(app, [
            ["version-1-0", "Extra app"],
            ["version-2-0", "Extra app"]
          ])
        expected_state_provider.stub(:available?) { true }

        subject.on_extra_app(app)
      end

      context "when the expected state provider is unavailable" do
        before do
          expected_state_provider.stub(:available?) { false }
        end

        it 'should not stop anything' do
          nudger.should_not_receive(:stop_instances_immediately)
          subject.on_extra_app(app)
        end
      end
    end
  end
end

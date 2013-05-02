require "spec_helper"

module HealthManager
  describe Harmonizer do
    let(:nudger) { mock.as_null_object }
    let(:expected_state_provider) { mock.as_null_object }
    let(:scheduler) { mock.as_null_object }
    let(:varz) { mock.as_null_object }
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
      }, varz, nudger, scheduler, nil, expected_state_provider)
    end

    describe "#prepare" do
      let(:app_state) { AppState.new("app-id") }

      describe "listeners" do
        context "on droplet update" do
          before { subject.prepare }
          after { AppState.remove_all_listeners }

          def test_listener
            AppState.notify_listener(:droplet_updated, app_state)
          end

          it "aborts all_pending_delayed_restarts" do
            subject.should_receive(:abort_all_pending_delayed_restarts).with(app_state)
            test_listener
          end

          it "updates expected state" do
            subject.should_receive(:update_expected_state)
            test_listener
          end

          it "sets expected_state_update_required" do
            app_state.should_receive(:expected_state_update_required=).with(true)
            test_listener
          end
        end
      end
    end

    describe "when app is considered to be an extra app" do
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

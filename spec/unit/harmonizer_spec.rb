require "spec_helper"

module HealthManager
  describe Harmonizer do
    describe "when app is considered to be an extra app" do
      let(:nudger) { mock }

      subject do
        Harmonizer.new({
          :health_manager_component_registry => {:nudger => nudger},
        })
      end

      it "stops all instances of the app" do
        app, _ = make_app(:num_instances => 1)
        heartbeats = make_heartbeat([app], :app_live_version => "version-1")
        app.process_heartbeat(heartbeats["droplets"][0])
        heartbeats = make_heartbeat([app], :app_live_version => "version-2")
        app.process_heartbeat(heartbeats["droplets"][0])

        nudger
          .should_receive(:stop_instances_immediately)
          .with(app, [
            ["version-1-0", "Extra app"],
            ["version-2-0", "Extra app"]
          ])

        subject.on_extra_app(app)
      end
    end
  end
end

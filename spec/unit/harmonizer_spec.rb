require "spec_helper"

module HealthManager
  describe Harmonizer do
    let(:nudger) { mock.as_null_object }
    let(:droplet_registry) { HealthManager::DropletRegistry.new }
    let(:desired_state) { mock.as_null_object }
    let(:actual_state) { mock.as_null_object }
    let(:scheduler) { mock.as_null_object }
    let(:varz) { HealthManager::Varz.new }
    let(:app) do
      app, _ = make_app(:num_instances => 1)
      heartbeats = make_heartbeat([app], :app_live_version => "version-1")
      app.process_heartbeat(heartbeats["droplets"][0])
      heartbeats = make_heartbeat([app], :app_live_version => "version-2")
      app.process_heartbeat(heartbeats["droplets"][0])
      app
    end
    let(:config) do
      {
        :intervals => {
          :max_droplets_in_varz => 10
        },
        :health_manager_component_registry => {:nudger => nudger}
      }
    end

    subject do
      Harmonizer.new(config, varz, nudger, scheduler, actual_state, desired_state, droplet_registry)
    end

    describe "#prepare" do
      let(:droplet) do
        droplet = Droplet.new("app-id")
        droplet.stub(:get_instance) do |ind|
          instances = [
            {"state" => "FLAPPING"},
            {"state" => "RUNNING"}
          ]
          instances[ind]
        end
        droplet
      end

      describe "listeners" do
        before { subject.prepare }
        after { Droplet.remove_all_listeners }

        describe "on missing instances" do
          context "when desired state update is required" do
            before { droplet.desired_state_update_required = false }

            context "when instance is flapping" do
              it "executes flapping policy" do
                subject.should_receive(:execute_flapping_policy).with(droplet, 0, {"state" => "FLAPPING"}, false)
                Droplet.notify_listener(:missing_instances, droplet, [0])
              end
            end

            context "when instance is NOT flapping" do
              it "executes NOT flapping policy" do
                nudger.should_receive(:start_instance).with(droplet, 1, NORMAL_PRIORITY)
                Droplet.notify_listener(:missing_instances, droplet, [1])
              end
            end
          end
        end

        describe "on extra_instances" do
          context "when desired state update is required" do
            before { droplet.desired_state_update_required = false }

            it "stops instances immediately" do
              nudger.should_receive(:stop_instances_immediately).with(droplet, [1, 2])
              Droplet.notify_listener(:extra_instances, droplet, [1, 2])
            end
          end
        end

        describe "on exit dea" do
          it "starts instance with high priority" do
            nudger.should_receive(:start_instance).with(droplet, 5, HIGH_PRIORITY)
            Droplet.notify_listener(:exit_dea, droplet, {"index" => 5})
          end
        end

        describe "on exit_crashed" do
          context "when instance is flapping" do
            it "executes flapping policy" do
              subject.should_receive(:execute_flapping_policy).with(droplet, 0, {"state" => "FLAPPING"}, true)
              Droplet.notify_listener(:exit_crashed, droplet, {"version" => 0, "index" => 0})
            end
          end

          context "when instance is NOT flapping" do
            it "executes NOT flapping policy" do
              nudger.should_receive(:start_instance).with(droplet, 1, LOW_PRIORITY)
              Droplet.notify_listener(:exit_crashed, droplet, {"version" => 1, "index" => 1})
            end
          end
        end

        describe "on droplet update" do
          def test_listener
            Droplet.notify_listener(:droplet_updated, droplet)
          end

          it "aborts all_pending_delayed_restarts" do
            subject.should_receive(:abort_all_pending_delayed_restarts).with(droplet)
            test_listener
          end

          it "updates desired state" do
            subject.should_receive(:update_desired_state)
            test_listener
          end

          it "sets desired_state_update_required" do
            droplet.should_receive(:desired_state_update_required=).with(true)
            test_listener
          end
        end
      end

      describe "scheduler" do
        it "sets a schedule for droplets_analysis" do
          scheduler.should_receive(:at_interval).with(:droplets_analysis)
          subject.prepare
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
        desired_state.stub(:available?) { true }

        subject.on_extra_app(app)
      end

      context "when the desired state provider is unavailable" do
        before do
          desired_state.stub(:available?) { false }
        end

        it 'should not stop anything' do
          nudger.should_not_receive(:stop_instances_immediately)
          subject.on_extra_app(app)
        end
      end
    end

    describe "#analyze_apps" do
      before do
        scheduler.stub(:task_running?) { false }
        desired_state.stub(:available?) { true }
      end

      def register_droplets(droplets_number)
        droplets_number.times do |i|
          droplet = droplet_registry.get(i)
          droplet.stub(:analyze)
          droplet.set_desired_state({
            'instances' => 1,
            'state' => STARTED,
            'version' => "123",
            'package_state' => STAGED,
            'updated_at' => Time.now.to_s
          })
        end
      end

      it "marks droplets_analysis task as running" do
        scheduler.should_receive(:mark_task_started).with(:droplets_analysis)
        subject.analyze_apps
      end

      it "when called in a row only analyizes the droplets once" do
        (ITERATIONS_PER_QUANTUM + 1).times do |i|
          droplet_registry.get(i).should_receive(:analyze).once
        end

        subject.analyze_apps
        subject.analyze_apps
      end

      context "when it starts" do
        it "resets realtime varz" do
          subject.varz.should_receive(:reset_realtime!)
          subject.analyze_apps
        end
      end

      context "when it is already run" do
        before do
          register_droplets(ITERATIONS_PER_QUANTUM + 1)
          subject.analyze_apps
        end

        it "does not reset varz" do
          subject.varz.should_not_receive(:reset_realtime!)
          subject.analyze_apps
        end

        it "starts with the next slice" do
          (ITERATIONS_PER_QUANTUM).times do |i|
            droplet_registry.get(i).should_not_receive(:analyze)
            droplet_registry.get(i).should_not_receive(:update_realtime_varz)
          end
          droplet_registry.get(ITERATIONS_PER_QUANTUM).should_receive(:analyze)
          droplet_registry.get(ITERATIONS_PER_QUANTUM).should_receive(:update_realtime_varz)
          subject.analyze_apps
        end
      end

      context "when it finishes" do
        it "sets varz analysis_loop_duration" do
          subject.analyze_apps
          expect(subject.varz[:analysis_loop_duration]).to_not be_nil
        end

        it "marks task as finished" do
          scheduler.should_receive(:mark_task_stopped).with(:droplets_analysis)
          subject.analyze_apps
        end

        context "when it run before" do
          before do
            register_droplets(ITERATIONS_PER_QUANTUM + 1)
            subject.analyze_apps
            subject.analyze_apps
          end

          it "resets current slice for next run" do
            droplet_registry.get(0).should_receive(:analyze)
            subject.analyze_apps
          end
        end
      end
    end
  end
end

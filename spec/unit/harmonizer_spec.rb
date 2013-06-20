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

    let(:droplet_desired_state) do
      {
        'instances' => 1,
        'state' => STARTED,
        'version' => "123",
        'package_state' => STAGED,
        'updated_at' => Time.now.to_s
      }
    end

    subject(:harmonizer) do
      Harmonizer.new(config, varz, nudger, scheduler, actual_state, desired_state, droplet_registry)
    end

    def register_droplets(droplets_number)
      droplets_number.times do |i|
        droplet = droplet_registry.get(i)
        droplet.stub(:analyze)
        droplet.set_desired_state(droplet_desired_state)
      end
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

    describe "on_missing_instances" do
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

      context "when desired state update is required" do
        before { droplet.desired_state_update_required = false }

        context "when instance is flapping" do
          before { droplet.stub(:missing_indices).and_return([0]) }
          it "executes flapping policy" do
            subject.should_receive(:execute_flapping_policy).with(droplet, 0, {"state" => "FLAPPING"}, false)
            harmonizer.on_missing_instances(droplet)
          end
        end

        context "when instance is NOT flapping" do
          before { droplet.stub(:missing_indices).and_return([1]) }
          it "executes NOT flapping policy" do
            nudger.should_receive(:start_instance).with(droplet, 1, NORMAL_PRIORITY)
            harmonizer.on_missing_instances(droplet)
          end
        end
      end
    end

    describe "#analyze_droplet" do
      let(:droplet) { double }

      before do
        droplet.stub(:is_extra? => false,
          :has_missing_indices? => false,
          :extra_instances => [],
          :update_extra_instances => nil,
          :prune_crashes => nil)
      end

      it "calls on_extra_app if the droplet is extra" do
        droplet.stub(:is_extra? => true)
        harmonizer.should_receive(:on_extra_app).with(droplet)
        harmonizer.analyze_droplet(droplet)
      end

      it "skips on_extra_app if the droplet is not extra" do
        harmonizer.should_not_receive(:on_extra_app)
        harmonizer.analyze_droplet(droplet)
      end

      it "calls on_missing_instances if the droplet has missing instances" do
        droplet.stub(:has_missing_indices? => true)
        harmonizer.should_receive(:on_missing_instances).with(droplet)
        droplet.should_receive(:reset_missing_indices)
        harmonizer.analyze_droplet(droplet)
      end

      it "skips on_missing_instances if the droplet does not have missing instances" do
        harmonizer.should_not_receive(:on_missing_instances)
        harmonizer.analyze_droplet(droplet)
      end

      it "calls on_extra_instances" do
        droplet.should_receive(:update_extra_instances)
        droplet.stub(:extra_instances => [1, 2, 3])

        harmonizer.should_receive(:on_extra_instances).with(droplet, [1, 2, 3])
        harmonizer.analyze_droplet(droplet)
      end

      it "prunes crashes" do
        droplet.should_receive(:prune_crashes)
        harmonizer.analyze_droplet(droplet)
      end
    end

    describe "#on_extra_instances" do
      let(:droplet) { double(:desired_state_update_required? => false) }
      let(:extra_instances) { [1, 2, 3] }
      it "tells the nudger to stop instances immediately" do
        nudger.should_receive(:stop_instances_immediately).with(droplet, extra_instances)

        harmonizer.on_extra_instances(droplet, extra_instances)
      end

      it "does not tell the nudger to stop instances immediately if a desired state update is required" do
        droplet.stub(:desired_state_update_required? => true)

        nudger.should_not_receive(:stop_instances_immediately)

        harmonizer.on_extra_instances(droplet, extra_instances)
      end

      it "does not tell the nudger to stop instances immediately if there are no extra instances" do
        nudger.should_not_receive(:stop_instances_immediately)

        harmonizer.on_extra_instances(droplet, [])
      end
    end

    describe "on_exit_crashed" do
      let(:instance) { {} }
      let(:droplet) { double(:get_instance => instance) }

      it "executes flapping policy if instance is flapping" do
        instance["state"] = FLAPPING
        harmonizer.should_receive(:execute_flapping_policy).with(droplet, 1, instance, true)
        harmonizer.on_exit_crashed(droplet, {"index" => 1})
      end

      it "tells the nudger to start the instance" do
        nudger.should_receive(:start_instance).with(droplet, 1, HealthManager::LOW_PRIORITY)
        harmonizer.on_exit_crashed(droplet, {"index" => 1})
      end
    end

    describe "#analyze_apps" do
      before do
        scheduler.stub(:task_running?) { false }
        subject.stub(:analyze_droplet)
        desired_state.stub(:available?) { true }
      end

      it "when called in a row only analyizes the droplets once" do
        (ITERATIONS_PER_QUANTUM + 1).times do |i|
          subject.should_receive(:analyze_droplet).with(droplet_registry.get(i)).once
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
            subject.should_not_receive(:analyze_droplet).with(droplet_registry.get(i))
            droplet_registry.get(i).should_not_receive(:update_realtime_varz)
          end
          subject.should_receive(:analyze_droplet).with(droplet_registry.get(ITERATIONS_PER_QUANTUM))
          droplet_registry.get(ITERATIONS_PER_QUANTUM).should_receive(:update_realtime_varz)
          subject.analyze_apps
        end
      end

      context "when it finishes" do
        it "sets varz analysis_loop_duration" do
          subject.analyze_apps
          expect(subject.varz[:analysis_loop_duration]).to_not be_nil
        end

        context "when it run before" do
          before do
            register_droplets(ITERATIONS_PER_QUANTUM + 1)
            subject.analyze_apps
            subject.analyze_apps
          end

          it "resets current slice for next run" do
            subject.should_receive(:analyze_droplet).with(droplet_registry.get(0))
            subject.analyze_apps
          end
        end
      end
    end

    describe "update_desired_state" do
      it "updates desired state" do
        desired_state.should_receive(:update)
        subject.update_desired_state
      end

      it "resets desired varz" do
        varz.should_receive(:reset_desired!)
        subject.update_desired_state
      end

      it "updates user counts" do
        desired_state.should_receive(:update_user_counts)
        subject.update_desired_state
      end
    end

    describe "on_exit_dea" do
      let(:droplet) { Droplet.new(2) }
      it "tells nudger to start instance" do
        nudger.should_receive(:start_instance).with(droplet, 1, HealthManager::HIGH_PRIORITY)
        harmonizer.on_exit_dea(droplet, {"index" => 1})
      end
    end

    describe "on_droplet_updated" do
      let(:droplet) { double(:pending_restarts => [], :desired_state_update_required= => nil) }
      it "sets droplet desired state updated" do
        droplet.should_receive(:desired_state_update_required=).with(true)
        harmonizer.on_droplet_updated(droplet, {})
      end

      it "aborts all pending delayed restarts" do
        harmonizer.should_receive(:abort_all_pending_delayed_restarts).with(droplet)
        harmonizer.on_droplet_updated(droplet, {})
      end

      it "updates desired state" do
        harmonizer.should_receive(:update_desired_state).with(no_args)
        harmonizer.on_droplet_updated(droplet, {})
      end
    end
  end
end

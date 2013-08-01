require "spec_helper"

module HealthManager
  describe Harmonizer do
    let(:nudger) { double.as_null_object }
    let(:droplet_registry) { HealthManager::DropletRegistry.new }
    let(:desired_state) { double.as_null_object }
    let(:actual_state) { double.as_null_object }
    let(:scheduler) { double.as_null_object }
    let(:varz) { HealthManager::Varz.new }
    let(:app) do
      app, _ = make_app(:num_instances => 1)
      heartbeats = make_heartbeat_message([app], :app_live_version => "version-1")
      app.process_heartbeat(HealthManager::Heartbeat.new(heartbeats[:droplets][0]))
      heartbeats = make_heartbeat_message([app], :app_live_version => "version-2")
      app.process_heartbeat(HealthManager::Heartbeat.new(heartbeats[:droplets][0]))
      app
    end

    let(:droplets_analyzed_per_iteration) { 40 }

    let(:config) do
      {
        :number_of_droplets_analyzed_per_analysis_iteration => droplets_analyzed_per_iteration,
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

    subject(:harmonizer) { Harmonizer.new(varz, nudger, scheduler, actual_state, desired_state, droplet_registry) }

    before { HealthManager::Config.load(config) }

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
        nudger.should_receive(:stop_instances_immediately).with(
          app,
          {
            "version-1-0" => {
              :version => "version-1",
              :reason => "Extra app"
            },
            "version-2-0"=>{
              :version => "version-2",
              :reason => "Extra app"
            }
          }
        )

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
      let(:flapping_instance) { double(:flapping_instance, :flapping? => true) }
      let(:not_flapping_instance) { double(:running_instance, :flapping? => false) }

      let(:droplet) do
        droplet = Droplet.new("app-id")
        droplet.stub(:get_instance) do |ind|
          instances = [
            flapping_instance,
            not_flapping_instance
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
            subject.should_receive(:execute_flapping_policy).with(droplet, flapping_instance, false)
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
      let(:instance) { double(:app_instance) }
      let(:droplet) { double(:get_instance => instance) }

      it "executes flapping policy if instance is flapping" do
        instance.stub(:flapping? => true)
        harmonizer.should_receive(:execute_flapping_policy).with(droplet, instance, true)
        harmonizer.on_exit_crashed(droplet, { :index => 1, :version => 'some-version' })
      end

      it "tells the nudger to start the instance" do
        instance.stub(:flapping? => false)
        nudger.should_receive(:start_instance).with(droplet, 1, HealthManager::LOW_PRIORITY)
        harmonizer.on_exit_crashed(droplet, { :index => 1, :version => 'some-version' })
      end
    end

    describe "#analyze_apps" do
      before do
        scheduler.stub(:task_running?) { false }
        subject.stub(:analyze_droplet)
        desired_state.stub(:available?) { true }
      end

      it "when called in a row only analyizes the droplets once" do
        (droplets_analyzed_per_iteration + 1).times do |i|
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
          register_droplets(droplets_analyzed_per_iteration + 1)
          subject.analyze_apps
        end

        it "does not reset varz" do
          subject.varz.should_not_receive(:reset_realtime!)
          subject.analyze_apps
        end

        it "starts with the next slice" do
          (droplets_analyzed_per_iteration).times do |i|
            subject.should_not_receive(:analyze_droplet).with(droplet_registry.get(i))
            droplet_registry.get(i).should_not_receive(:update_realtime_varz)
          end
          subject.should_receive(:analyze_droplet).with(droplet_registry.get(droplets_analyzed_per_iteration))
          droplet_registry.get(droplets_analyzed_per_iteration).should_receive(:update_realtime_varz)
          subject.analyze_apps
        end
      end

      context "when it finishes" do
        it "sets varz analysis_loop_duration" do
          subject.analyze_apps
          expect(subject.varz[:analysis_loop_duration]).to_not be_nil
        end

        it "publishes realtime varz" do
          subject.varz.should_receive(:publish_realtime_stats)
          subject.analyze_apps
        end

        context "when it run before" do
          before do
            register_droplets(droplets_analyzed_per_iteration + 1)
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
        harmonizer.on_exit_dea(droplet, { :index => 1})
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

    describe "#executing_flapping_policy" do
      let(:droplet) { double(:droplet) }
      let(:instance) { HealthManager::AppInstance.new('version', 0, 'abc') }

      context "when the instance is not pending a restart" do
        before { instance.stub(:pending_restart?) { false } }

        context "when the instance should give up being restarted" do
          before { instance.stub(:giveup_restarting?) { true } }

          it "should not schedule a delayed restart" do
            scheduler.should_not_receive(:after)
            instance.should_not_receive(:mark_pending_restart_with_receipt!)
            subject.execute_flapping_policy(droplet, instance, true)
          end
        end

        context "when the instance should be restarted" do
          before { instance.stub(:giveup_restarting?) { false} }

          it 'should schedule a restart and mark the instance as pending a restart' do
            scheduler.stub(:after).with(kind_of(Float)).and_return(:my_receipt)
            instance.should_receive(:mark_pending_restart_with_receipt!).with(:my_receipt)
            subject.execute_flapping_policy(droplet, instance, false)
          end

          it 'should restart the instance correctly' do
            scheduler.stub(:after).with(kind_of(Float)).and_yield
            instance.stub(:mark_pending_restart_with_receipt!)

            instance.should_receive(:unmark_pending_restart!)
            nudger.should_receive(:start_flapping_instance_immediately).with(droplet, 0)

            subject.execute_flapping_policy(droplet, instance, false)
          end
        end
      end

      context "when the instance is pending a restart" do
        before { instance.stub(:pending_restart?) { true } }

        it 'should not schedule a restart' do
          scheduler.should_not_receive(:after)
          instance.should_not_receive(:mark_pending_restart_with_receipt!)
          subject.execute_flapping_policy(droplet, instance, true)
        end
      end
    end
  end
end

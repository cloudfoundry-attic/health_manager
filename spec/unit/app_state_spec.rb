require 'spec_helper'

module HealthManager
  describe AppState do
    after { AppState.remove_all_listeners }

    before do
      AppState.remove_all_listeners
      AppState.heartbeat_deadline = 10
      AppState.flapping_death = 1
      AppState.droplet_gc_grace_period = 60
      AppState.expected_state_update_deadline = 50
    end

    describe "#analyze" do
      before { Timecop.freeze }
      after { Timecop.return }

      let!(:app) { described_class.new(1) }

      before do
        @called_extra_app = nil
        AppState.add_listener(:extra_app) do |app|
          @called_extra_app = app
        end
      end

      context "when expected was not updated" do
        it "notifies of an extra app after expected state was not recently updated" do
          Timecop.travel(AppState.expected_state_update_deadline)
          app.analyze
          @called_extra_app.should be_nil

          Timecop.travel(1)
          app.analyze
          @called_extra_app.should == app
        end
      end

      context "when expected was updated" do
        before { app.set_expected_state(make_expected_state) }

        it "notifies of an extra app after expected state was not recently updated" do
          Timecop.travel(AppState.expected_state_update_deadline)
          app.analyze
          @called_extra_app.should be_nil

          Timecop.travel(1)
          app.analyze
          @called_extra_app.should == app
        end
      end
    end

    it 'should not invoke missing_instances for non-staged states' do
      app, _ = make_app(:package_state => 'PENDING')
      app.missing_indices.should == []
    end

    it 'should not invoke missing_instances for instances with pending restarts' do
      app, _ = make_app
      app.add_pending_restart(1,nil)
      app.add_pending_restart(3,nil)

      app.missing_indices.should == [0,2]
    end

    it 'should process crash message' do
      app, _ = make_app
      invoked = false

      AppState.add_listener :exit_crashed do
        invoked = true
      end
      message = make_crash_message(app)
      app.process_exit_crash(message)
      invoked.should be_true

      app.crashes.should have_key(message['instance'])
    end

    it 'should invoke missing_instances event handler' do
      future_answer = [1, 3]
      event_handler_invoked = false
      app, _ = make_app

      #no heartbeats arrived yet, so all instances are assumed missing
      app.missing_indices.should == [0, 1, 2, 3]

      AppState.add_listener :missing_instances do |a, indices|
        a.should == app
        indices.should == future_answer
        event_handler_invoked = true
      end

      event_handler_invoked.should be_false
      hbs = make_heartbeat([app])['droplets']

      hbs.delete_at(3)
      hbs.delete_at(1)

      hbs.each {|hb|
        app.process_heartbeat(hb)
      }

      app.missing_indices.should == future_answer
      event_handler_invoked.should be_false

      app.analyze

      event_handler_invoked.should be_false

      AppState.heartbeat_deadline = 0
      app.analyze

      event_handler_invoked.should be_true
    end

    it 'should invoke extra_instances event handler' do
      app, expected = make_app
      extra_instance_id = expected[:live_version]+"-0"

      future_answer = [[extra_instance_id, "Extra instance"]]
      event_handler_invoked = false

      #no heartbeats arrived yet, so all instances are assumed missing

      AppState.add_listener :extra_instances do |a, indices|
        a.should == app
        indices.should == future_answer
        event_handler_invoked = true
      end

      event_handler_invoked.should be_false
      hbs = make_heartbeat([app])['droplets']

      hbs << hbs.first.dup
      hbs.first['index'] = 4

      hbs.each {|hb| app.process_heartbeat(hb) }
      event_handler_invoked.should be_false
      app.analyze
      event_handler_invoked.should be_true
    end

    describe "#ripe_for_gc?" do
      before { Timecop.freeze }
      after { Timecop.return }

      let!(:app_with_expected_state) { make_app }
      let!(:expected_state) { app_with_expected_state.last }
      let!(:app) { app_with_expected_state.first }

      it "is not ripe at first" do
        app.should_not be_ripe_for_gc
      end

      context "when app was never updated" do
        it "can be gc-ed at the end of gc period" do
          Timecop.travel(end_of_gc_period = AppState.droplet_gc_grace_period)
          app.should_not be_ripe_for_gc

          Timecop.travel(after_end_of_gc_period = 1)
          app.should be_ripe_for_gc
        end
      end

      context "when app was updated via change in expected state" do
        before do
          Timecop.travel(during_gc_period = 10)
          app.set_expected_state(expected_state)
        end

        it "cannot be gc-ed at the end of gc period " +
           "because expected state indicates that app *should* be running" do
          Timecop.travel(end_of_gc_period = AppState.droplet_gc_grace_period - 10)
          app.should_not be_ripe_for_gc

          Timecop.travel(after_end_of_gc_period = 1)
          app.should_not be_ripe_for_gc

          Timecop.travel(after_end_of_next_gc_period = 10)
          app.should be_ripe_for_gc
        end
      end

      context "when app was updated via heartbeat" do
        before do
          Timecop.travel(during_gc_period = 10)
          app.process_heartbeat(make_heartbeat([app]))
        end

        it "can be gc-ed at the end of the gc period " +
           "because heartbeat alone does not indicate that app *should* be running" do
          Timecop.travel(end_of_gc_period = AppState.droplet_gc_grace_period - 10)
          app.should_not be_ripe_for_gc

          Timecop.travel(after_end_of_gc_period = 1)
          app.should be_ripe_for_gc
        end
      end
    end

    describe "#all_instances" do
      let(:app) { a, _ = make_app(:num_instances => 1); a }

      context "when there are multiple instances of multiple versions" do
        before do
          heartbeats = make_heartbeat([app], :app_live_version => "version-1")
          app.process_heartbeat(heartbeats["droplets"][0])
          heartbeats = make_heartbeat([app], :app_live_version => "version-2")
          app.process_heartbeat(heartbeats["droplets"][0])
        end

        it "returns list of all instances for all versions" do
          instances = app.all_instances.map { |i| i["instance"] }
          instances.should =~ %w(version-1-0 version-2-0)
        end
      end

      context "when there are no instances" do
        it "returns empty list" do
          app.all_instances.should == []
        end
      end
    end
  end
end

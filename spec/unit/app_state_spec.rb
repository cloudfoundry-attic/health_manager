require 'spec_helper'

describe HealthManager do

  include HealthManager::Common

  after :each do
    AppState.remove_all_listeners
  end

  describe "AppState" do
    before(:each) do
      AppState.remove_all_listeners
      AppState.heartbeat_deadline = 10
      AppState.droplet_gc_grace_period = 60
    end

    it 'should become ripe for GC after inactivity' do
      app, _ = make_app
      app.should_not be_ripe_for_gc

      Timecop.travel(Time.now + AppState.droplet_gc_grace_period + 10)
      app.should be_ripe_for_gc
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
  end
end

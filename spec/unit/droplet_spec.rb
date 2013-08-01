require 'spec_helper'

describe HealthManager::Droplet do
  let(:droplet_gc_grace_period) { 60 }
  let(:flapping_timeout) { 500 }
  let(:config) do
    {
      :intervals => {
        :droplet_gc_grace_period => droplet_gc_grace_period,
        :heartbeat_deadline => 10,
        :flapping_death => 1,
        :desired_state_update_deadline => 50,
        :flapping_timeout => flapping_timeout
      }
    }
  end

  before { HealthManager::Config.load(config) }

  describe "handling instances that start and then crash" do
    let(:droplet) { HealthManager::Droplet.new(2) }
    before do
      heartbeat_properties = {
        :droplet => 2,
        :version => "abc",
        :index => 0,
        :state_timestamp => now,
        :cc_partition => 'default'
      }
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::CRASHED))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::CRASHED))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "gamma", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "gamma", :state => HealthManager::CRASHED))
      )
    end

    it "should not report any extra instances" do
      expect(droplet.extra_instances.keys).to eql([])
    end
  end

  describe "when an instance is evacuated, and then a new instance starts" do
    let(:droplet) { HealthManager::Droplet.new(2) }
    before do
      heartbeat_properties = {
        :droplet => 2,
        :version => "abc",
        :index => 0,
        :state_timestamp => now,
        :cc_partition => 'default'
      }
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::RUNNING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::RUNNING))
      )
      droplet.mark_instance_as_down("abc",0,"alpha")
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::RUNNING))
      )
    end

    it "should not report any extra instances" do
      expect(droplet.extra_instances.keys).to eql([])
    end
  end

  describe "when three instances with the same index show up" do
    let(:droplet) { HealthManager::Droplet.new(2) }

    let(:heartbeat_properties) do
    {
      :droplet => 2,
        :version => "abc",
        :index => 0,
        :state_timestamp => now,
      :cc_partition => 'default'
    }
    end

    it "should kill the instances one at a time" do
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "alpha", :state => HealthManager::RUNNING))
      )

      expect(droplet.extra_instances.keys).to eql([])

      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "beta", :state => HealthManager::RUNNING))
      )

      expect(droplet.extra_instances.keys).to eql(["alpha"])

      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "gamma", :state => HealthManager::STARTING))
      )
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(heartbeat_properties.merge(:instance => "gamma", :state => HealthManager::RUNNING))
      )

      expect(droplet.extra_instances.keys).to eql(["beta"])
    end
  end

  describe "handling multiple instances with the same index" do
    let(:droplet) { HealthManager::Droplet.new(2) }
    before do
      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(
          :droplet => 2,
          :version => "abc",
          :instance => "alpha",
          :index => 0,
          :state => HealthManager::RUNNING,
          :state_timestamp => now,
          :cc_partition => 'default'
        )
      )

      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(
          :droplet => 2,
          :version => "abc",
          :instance => "alpha",
          :index => 0,
          :state => HealthManager::RUNNING,
          :state_timestamp => now,
          :cc_partition => 'default'
        )
      )

      droplet.process_heartbeat(
        HealthManager::Heartbeat.new(
          :droplet => 2,
          :version => "abc",
          :instance => "beta",
          :index => 0,
          :state => HealthManager::RUNNING,
          :state_timestamp => now,
          :cc_partition => 'default'
        )
      )
    end

    context 'alpha, beta, alpha' do
      before do
        expect(droplet.extra_instances.keys).to eql([])
        droplet.process_heartbeat(
          HealthManager::Heartbeat.new(
            :droplet => 2,
            :version => "abc",
            :instance => "alpha",
            :index => 0,
            :state => HealthManager::RUNNING,
            :state_timestamp => now,
            :cc_partition => 'default'
          )
        )
      end

      it 'kill beta, keep alpha as the guid' do
        expect(droplet.extra_instances).to have(1).item
        expect(droplet.extra_instances.keys).to eql(["beta"])
        expect(droplet.get_instance(0, "abc").guid).to eql("alpha")
      end

      it 'should report number of running instances by version as the number of unique instance guids that have come in' do
        expect(droplet.number_of_running_instances_by_version['abc']).to eq(2)
      end
    end

    context 'alpha, beta, beta' do
      before do
        expect(droplet.extra_instances.keys).to eql([])
        droplet.process_heartbeat(
          HealthManager::Heartbeat.new(
            :droplet => 2,
            :version => "abc",
            :instance => "beta",
            :index => 0,
            :state => HealthManager::RUNNING,
            :state_timestamp => now,
            :cc_partition => 'default'
          )
        )
      end

      it 'kill alpha, assign beta as the guid' do
        expect(droplet.extra_instances).to have(1).item
        expect(droplet.extra_instances.keys).to eql(["alpha"])
        expect(droplet.get_instance(0, "abc").guid).to eql("beta")
      end

      it 'should report number of running instances by version as the number of unique instance guids that have come in' do
        expect(droplet.number_of_running_instances_by_version['abc']).to eq(2)
      end
    end
  end

  describe "process_heartbeat" do
    let(:droplet) { HealthManager::Droplet.new(2) }
    let(:droplet_beat_1) do
      HealthManager::Heartbeat.new(
        :droplet => 2,
        :version => "abc-def",
        :instance => "someinstance1",
        :index => 0,
        :state => HealthManager::RUNNING,
        :state_timestamp => now,
        :cc_partition => 'default'
      )
    end
    let(:droplet_beat_2) do
      HealthManager::Heartbeat.new(
        :droplet => 2,
        :version => "abc-def",
        :instance => "someinstance2",
        :index => 1,
        :state => HealthManager::RUNNING,
        :state_timestamp => now,
        :cc_partition => 'default'
      )
    end

    subject do
      droplet.process_heartbeat(droplet_beat_1)
      droplet.process_heartbeat(droplet_beat_2)
    end

    it "sets versions correctly" do
      subject
      expect(droplet.get_instance(0, "abc-def")).to be_running
      expect(droplet.get_instance(1, "abc-def")).to be_running
    end
  end

  it 'should return instances with pending_restarts' do
    app, _ = make_app
    app.get_instance(1).mark_pending_restart_with_receipt!('foo')
    app.get_instance(3).mark_pending_restart_with_receipt!('bar')

    app.pending_restarts.map(&:index).should == [1, 3]
  end

  it 'should not invoke missing_instances for non-staged states' do
    app, _ = make_app('package_state' => 'PENDING')
    app.missing_indices.should == []
  end

  it 'should not invoke missing_instances for instances with pending restarts' do
    app, _ = make_app
    app.get_instance(1).mark_pending_restart_with_receipt!('foo')
    app.get_instance(3).mark_pending_restart_with_receipt!('bar')

    app.missing_indices.should == [0, 2]
  end

  it 'should process crash message' do
    app, _ = make_app

    message = make_crash_message(app)
    app.process_exit_crash(message)

    app.crashes.should have_key(message[:instance])
  end

  it 'should have missing indices' do
    missing_indices = [1, 3]
    app, _ = make_app

    #no heartbeats arrived yet, so all instances are assumed missing
    app.missing_indices.should == [0, 1, 2, 3]

    hbs = make_heartbeat_message([app])[:droplets]

    hbs.delete_at(3)
    hbs.delete_at(1)

    hbs.each { |hb|
      app.process_heartbeat(HealthManager::Heartbeat.new(hb))
    }

    expect(app.missing_indices).to eql(missing_indices)
  end

  it 'should have extra instances' do
    app, _ = make_app

    #no heartbeats arrived yet, so all instances are assumed missing

    hbs = make_heartbeat_message([app])[:droplets]

    hbs << hbs.first.dup
    hbs.first[:index] = 4

    hbs.each { |hb| app.process_heartbeat(HealthManager::Heartbeat.new(hb)) }
    app.update_extra_instances
    expect(app.extra_instances.size).to eq 1
  end

  describe "ripe_for_gc?" do
    before { Timecop.freeze }
    after { Timecop.return }

    let!(:app_with_desired_state) { make_app }
    let!(:desired_state) { app_with_desired_state.last }
    let!(:app) { app_with_desired_state.first }

    it "is not ripe at first" do
      app.should_not be_ripe_for_gc
    end

    context "when app was never updated" do
      it "can be gc-ed at the end of gc period" do
        Timecop.travel(end_of_gc_period = droplet_gc_grace_period)
        app.should_not be_ripe_for_gc

        Timecop.travel(after_end_of_gc_period = 1)
        app.should be_ripe_for_gc
      end
    end

    context "when app was updated via change in desired state" do
      before do
        Timecop.travel(during_gc_period = 10)
        app.set_desired_state(desired_state)
      end

      it "cannot be gc-ed at the end of gc period " +
        "because desired state indicates that app *should* be running" do
        Timecop.travel(end_of_gc_period = droplet_gc_grace_period - 10)
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
        app.process_heartbeat(HealthManager::Heartbeat.new(make_heartbeat_message([app])[:droplets][0]))
      end

      it "can be gc-ed at the end of the gc period " +
        "because heartbeat alone does not indicate that app *should* be running" do
        Timecop.travel(end_of_gc_period = droplet_gc_grace_period - 10)
        app.should_not be_ripe_for_gc

        Timecop.travel(after_end_of_gc_period = 1)
        app.should be_ripe_for_gc
      end
    end
  end

  describe "#update_realtime_varz" do
    let(:droplet) do
      make_app(:num_instances => 23)[0].tap do |app|
        app.process_exit_crash(make_crash_message(app))
      end
    end
    let(:varz) { HealthManager::Varz.new }
    let(:beat) do
      heart = make_heartbeat_message([droplet])
      heart[:droplets][0][:state] = HealthManager::DOWN # Flapping from multiple crashes
      heart[:droplets][1][:state] = HealthManager::DOWN
      heart[:droplets][2][:state] = HealthManager::STARTING
      (3...droplet.num_instances).each do |time|
        heart[:droplets][time][:state] = HealthManager::RUNNING
      end
      heart
    end
    let(:droplet_state) { HealthManager::STARTED }

    subject(:update_realtime_varz) { droplet.update_realtime_varz(varz) }
    let(:flapping_timeout) { 3456 }

    before do
      droplet.process_exit_crash(make_crash_message(droplet))
      droplet.instance_variable_set(:@state, droplet_state)
      beat[:droplets].each do |b|
        droplet.process_heartbeat(HealthManager::Heartbeat.new(b))
      end
    end

    it "increments the total apps on varz" do
      expect { update_realtime_varz }.to change { varz[:total_apps] }.by(1)
    end

    it "adds the number of instances that the droplet knows about" do
      expect { update_realtime_varz }.to change { varz[:total_instances] }.by(23)
    end

    it "adds the number of crashed instances that the droplet knows about" do
      expect { update_realtime_varz }.to change { varz[:crashed_instances] }.by(1)
    end

    context "when the droplet is supposed to be started" do
      it "increments the running apps" do
        expect { update_realtime_varz }.to change { varz[:running][:apps] }.by(1)
      end

      it 'should increment running_instances for each running and starting instance' do
        expect { update_realtime_varz }.to change { varz[:running_instances] }.by(21)
      end

      it 'should increment missing_instances for each down instance' do
        expect { update_realtime_varz }.to change { varz[:missing_instances] }.by(1)
      end

      it 'should increment flapping_instances for each flapping instance' do
        expect { update_realtime_varz }.to change { varz[:flapping_instances] }.by(1)
      end

      it 'should add crashes to the running crashes' do
        expect { update_realtime_varz }.to change { varz[:running][:crashes] }.by(1)
      end

      it 'should increment running running_instances for each running and starting instance' do
        expect { update_realtime_varz }.to change { varz[:running][:running_instances] }.by(21)
      end

      it 'should increment running missing_instances for each down instance' do
        expect { update_realtime_varz }.to change { varz[:running][:missing_instances] }.by(1)
      end

      it 'should increment running flapping_instances for each flapping instance' do
        expect { update_realtime_varz }.to change { varz[:running][:flapping_instances] }.by(1)
      end
    end

    context "when the droplet is not supposed to be started" do
      let(:droplet_state) { HealthManager::STOPPED }

      it "does not increment the running apps" do
        expect { update_realtime_varz }.not_to change { varz[:running][:apps] }
      end

      it 'should not increment running_instances for each running and starting instance' do
        expect { update_realtime_varz }.not_to change { varz[:running_instances] }
      end

      it 'should not increment missing_instances for each down instance' do
        expect { update_realtime_varz }.not_to change { varz[:missing_instances] }
      end

      it 'should not increment flapping_instances for each flapping instance' do
        expect { update_realtime_varz }.not_to change { varz[:flapping_instances] }
      end

      it 'should not add crashes to the running crashes' do
        expect { update_realtime_varz }.not_to change { varz[:running][:crashes] }
      end

      it 'should not increment running running_instances for each running and starting instance' do
        expect { update_realtime_varz }.not_to change { varz[:running][:running_instances] }
      end

      it 'should not increment running missing_instances for each down instance' do
        expect { update_realtime_varz }.not_to change { varz[:running][:missing_instances] }
      end

      it 'should not increment running flapping_instances for each flapping instance' do
        expect { update_realtime_varz }.not_to change { varz[:running][:flapping_instances] }
      end
    end
  end

  describe "update_extra_instances" do
    let(:heartbeats) do
      [
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "123",
          :timestamp => Time.now.to_i,
          :index => 0,
          :instance => 'guid',
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "123",
          :timestamp => Time.now.to_i,
          :index => 1,
          :instance => 'guid',
          :state_timestamp => 0
        )
      ]
    end

    let(:droplet) do
      droplet = HealthManager::Droplet.new(2)
      heartbeats.each { |beat| droplet.process_heartbeat(beat) }
      droplet.stub(:state) { HealthManager::RUNNING }
      droplet.stub(:num_instances) { 2 }
      droplet.stub(:live_version) { "123" }
      droplet
    end

    context "if the droplet was stopped" do
      before { droplet.stub(:state) { HealthManager::STOPPED } }

      it "removes instances" do
        droplet.update_extra_instances
        expect(droplet.get_instances('123')).to eql({})
      end
    end

    context "if there are extra instances" do
      before { droplet.stub(:num_instances) { 1 } }

      it "removes instances" do
        droplet.update_extra_instances
        expect(droplet.get_instances("123")).to have(1).item
      end
    end

    context "if their version don't match live version" do
      before { droplet.stub(:live_version) { "456" } }

      it "removes instances" do
        droplet.update_extra_instances
        expect(droplet.get_instances('123')).to eql({})
      end
    end

    context "when there are too many instances running" do
      context "and the desired number is 1" do
        before { droplet.stub(:num_instances) { 1 } }

        context "and the first instance is an old version" do
          let(:heartbeats) do
            [
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "some-old-version",
                :timestamp => Time.now.to_i,
                :index => 0,
                :instance => 'guid',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 1,
                :instance => 'guid2',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 2,
                :instance => 'guid3',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 3,
                :instance => 'guid4',
                :state_timestamp => 0
              )
            ]
          end

          it "keeps one of the running instances of the current version" do
            droplet.update_extra_instances
            expect(droplet.get_instances('123')).to have(1).item
          end
        end

        context "and the last instance is an old version" do
          let(:heartbeats) do
            [
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 1,
                :instance => 'guid',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 2,
                :instance => 'guid',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "123",
                :timestamp => Time.now.to_i,
                :index => 3,
                :instance => 'guid',
                :state_timestamp => 0
              ),
              HealthManager::Heartbeat.new(
                :state => HealthManager::RUNNING,
                :version => "some-old-version",
                :timestamp => Time.now.to_i,
                :index => 0,
                :instance => 'guid',
                :state_timestamp => 0
              )
            ]
          end

          it "keeps one of the running instances of the current version" do
            droplet.update_extra_instances
            expect(droplet.get_instances('123')).to have(1).item
          end
        end
      end
    end
  end


  describe "reporting on instances" do
    before do
      heartbeats = [
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "123",
          :timestamp => Time.now.to_i,
          :instance => "beef",
          :index => 0,
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::STOPPED,
          :version => "123",
          :timestamp => Time.now.to_i,
          :instance => "cafe",
          :index => 2,
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::STARTING,
          :version => "123",
          :timestamp => Time.now.to_i,
          :instance => "face",
          :index => 3,
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "123",
          :timestamp => Time.now.to_i,
          :instance => "dead",
          :index => 1,
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "abc",
          :timestamp => Time.now.to_i,
          :instance => "abab",
          :index => 0,
          :state_timestamp => 0
        ),
        HealthManager::Heartbeat.new(
          :state => HealthManager::RUNNING,
          :version => "abc",
          :timestamp => Time.now.to_i,
          :instance => "baba",
          :index => 0,
          :state_timestamp => 0
        )
      ]

      @droplet = HealthManager::Droplet.new(2)
      heartbeats.each { |beat| @droplet.process_heartbeat(beat) }
    end

    describe "number_of_running_instances_by_version" do
      it "should return a map of versions to running instances" do
        expect(@droplet.number_of_running_instances_by_version).to eql({ "123" => 2, "abc" => 2 })
      end
    end

    describe "all_starting_or_running_instances" do
      specify do
        expect(@droplet.all_starting_or_running_instances.count).to eql(4)
        expect(@droplet.all_starting_or_running_instances.map(&:guid)).to match_array(%w(beef face dead baba))
      end
    end
  end
end

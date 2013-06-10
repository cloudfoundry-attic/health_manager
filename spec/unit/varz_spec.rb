require 'spec_helper'

describe HealthManager::Varz do
  describe "#new" do
    its([:total_apps]) { should eq 0 }
    its([:total_instances]) { should eq 0 }
    its([:running_instances]) { should eq 0 }
    its([:missing_instances]) { should eq 0 }
    its([:crashed_instances]) { should eq 0 }
    its([:flapping_instances]) { should eq 0 }
    its([:running]) do
      should eq(
        :apps => 0,
        :crashes => 0,
        :running_instances => 0,
        :missing_instances => 0,
        :flapping_instances => 0
      )
    end
    its([:total_users]) { should eq 0 }
    its([:users]) { should eq [] }
    its([:apps]) { should eq [] }
    its([:total]) do
      should eq(
        :apps => 0,
        :started_apps => 0,
        :instances => 0,
        :started_instances => 0,
        :memory => 0,
        :started_memory => 0
      )
    end
    its([:queue_length]) { should eq 0 }
    its([:heartbeat_msgs_received]) { should eq 0 }
    its([:droplet_exited_msgs_received]) { should eq 0 }
    its([:droplet_updated_msgs_received]) { should eq 0 }
    its([:healthmanager_status_msgs_received]) { should eq 0 }
    its([:healthmanager_health_request_msgs_received]) { should eq 0 }
    its([:healthmanager_droplet_request_msgs_received]) { should eq 0 }
    its([:analysis_loop_duration]) { should eq 0 }
    its([:bulk_update_loop_duration]) { should eq 0 }
    its([:varz_publishes]) { should eq 0 }
    its([:varz_holds]) { should eq 0 }

    its([:droplets]) { should eq({}) } # FIXIT: remove once ready for production

    its([:state]) { should eq "RUNNING" }

    its([:last_up_known]) { should be_nil }
  end

  describe "#reset_desired!" do
    before do
      subject[:total][:apps] = 5
      subject[:total][:memory] = 2
      subject[:users] = %w[hi bye]
      subject[:apps] = %w[hey buddy]

      subject.reset_desired!
    end

    its([:users]) { should eq [] }
    its([:apps]) { should eq [] }
    its([:total]) do
      should eq(
        :apps => 0,
        :started_apps => 0,
        :instances => 0,
        :started_instances => 0,
        :memory => 0,
        :started_memory => 0
      )
    end
  end

  describe "#reset_realtime!" do
    before do
      subject[:running][:apps] = 5
      subject[:running][:running_instances] = 2
      subject[:total_apps] = 2
      subject[:total_instances] = 2
      subject[:running_instances] = 2
      subject[:missing_instances] = 2
      subject[:crashed_instances] = 2
      subject[:flapping_instances] = 2

      subject.reset_realtime!
    end

    its([:total_apps]) { should eq 0 }
    its([:total_instances]) { should eq 0 }
    its([:running_instances]) { should eq 0 }
    its([:missing_instances]) { should eq 0 }
    its([:crashed_instances]) { should eq 0 }
    its([:flapping_instances]) { should eq 0 }
    its([:running]) do
      should eq(
        :apps => 0,
        :crashes => 0,
        :running_instances => 0,
        :missing_instances => 0,
        :flapping_instances => 0
      )
    end
  end

  describe "#publish_desired_stats" do
    let(:create_time) { Time.parse("2013-03-23 01:43:27") }
    let(:publish_time) { Time.parse("2013-04-13 03:32:35") }

    before do
      subject[:total_instances] = 5
      Timecop.freeze(publish_time) { subject.publish_desired_stats }
    end

    subject do
      Timecop.freeze(create_time) { HealthManager::Varz.new }
    end

    its([:total_instances]) { should eq VCAP::Component.varz[:total_instances] }

    it "sets the time since the last reset" do
      expect(subject[:bulk_update_loop_duration]).to eq(publish_time - create_time)
    end

    context "when the desired stats have been reset" do
      let(:reset_time) { Time.parse("2013-04-12 05:23:54") }

      before do
        Timecop.freeze(reset_time) { subject.reset_desired! }
        Timecop.freeze(publish_time) { subject.publish_desired_stats }
      end

      it "sets the time since the last reset" do
        expect(subject[:bulk_update_loop_duration]).to eq(publish_time - reset_time)
      end
    end
  end

  describe "#publish" do
    before do
      subject[:total_users] = 42
      subject.publish
    end

    its([:total_users]) { should eq VCAP::Component.varz[:total_users] }
  end
end

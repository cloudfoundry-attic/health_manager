require 'spec_helper'

describe HealthManager do

  describe "Varz" do
    before :each do
      @v = Varz.new
    end

    def v; @v; end

    it 'should allow declaring counters' do
      v.declare_counter :counter1
      v.get(:counter1).should == 0
    end

    it 'should allow declaring nodes and subcounters' do
      v.declare_node :node
      v.declare_counter :node, :foo
      v.declare_node :node, :node1
      v.declare_counter :node, :node1, :foo
    end

    it 'should disallow double declarations' do
      v.declare_counter :foo
      v.declare_counter :bar
      vv = Varz.new
      vv.declare_counter :foo #ok to declare same counters for different Varz objects
      lambda { v.declare_counter(:foo).should raise_error ArgumentError }
    end

    it 'should disallow undeclared counters' do
      lambda { v.get :counter_bogus }.should raise_error ArgumentError
      lambda { v.inc :counter_bogus }.should raise_error ArgumentError
      v.declare_node :foo
      v.declare_counter :foo, :bar
      lambda { v.reset :foo, :bogus }.should raise_error ArgumentError
    end

    it 'should have correct held? predicate' do
      v.declare_node(:n)
      v.declare_counter(:n, :c1)
      v.declare_counter(:n, :c2)

      v.held?(:n).should be_false
      v.held?(:n, :c1).should be_false
      v.held?(:n, :c2).should be_false

      v.hold(:n, :c1)

      v.held?(:n).should be_false
      v.held?(:n, :c1).should be_true
      v.held?(:n, :c2).should be_false

      v.release(:n, :c1)
      v.hold(:n, :c2)

      v.held?(:n).should be_false
      v.held?(:n, :c1).should be_false
      v.held?(:n, :c2).should be_true

      v.hold(:n)

      v.held?(:n).should be_true
      v.held?(:n, :c1).should be_true
      v.held?(:n, :c2).should be_true
    end

    it 'should prevent bogus holding and releasing' do
      lambda { v.hold :bogus }.should raise_error ArgumentError
      v.declare_counter :boo
      lambda { v.release :boo }.should raise_error ArgumentError

      v.hold :boo
      v.release :boo
    end

    it 'should allow publishing, holding and releasing' do
      v.declare_counter :counter1

      v.declare_node :node1
      v.declare_counter :node1, :counter2

      v.declare_node :node1, :node2
      v.declare_counter :node1, :node2, :counter3

      #one held, but all incremented
      v.hold(:node1, :counter2)

      v.inc(:counter1)
      v.inc(:node1, :counter2)
      v.inc(:node1, :node2, :counter3)

      v.publish_not_held_recursively(res = {}, v.get_varz)

      res[:counter1].should == 1
      res[:node1][:counter2].should be_nil
      res[:node1][:node2][:counter3].should == 1

      #after release and republish, value is again available
      v.release(:node1, :counter2)
      v.publish_not_held_recursively(res, v.get_varz)

      res[:node1][:counter2].should == 1

      #now holding top-level entry
      v.hold(:counter1)
      v.inc(:counter1)
      v.inc(:node1, :counter2)
      v.inc(:node1, :node2, :counter3)

      v.publish_not_held_recursively(res, v.get_varz)

      res[:counter1].should == 1
      res[:node1][:counter2].should == 2
      res[:node1][:node2][:counter3].should == 2

      v.release(:counter1)
      v.publish_not_held_recursively(res, v.get_varz)

      res[:counter1].should == 2

      #now holding third-level entry

      v.hold(:node1, :node2, :counter3)

      v.inc(:counter1)
      v.inc(:node1, :counter2)
      v.inc(:node1, :node2, :counter3)

      v.publish_not_held_recursively(res, v.get_varz)

      res[:counter1].should == 3
      res[:node1][:counter2].should == 3
      res[:node1][:node2][:counter3].should == 2

      v.release(:node1, :node2, :counter3)
      v.publish_not_held_recursively(res, v.get_varz)

      res[:node1][:node2][:counter3].should == 3
    end

    it 'should properly increment and reset counters' do
      v.declare_counter :foo
      v.declare_node :node
      v.declare_counter :node, :bar

      v.get(:foo).should == 0
      v.inc(:foo).should == 1
      v.get(:foo).should == 1

      v.add :foo, 10
      v.get(:foo).should == 11
      v.get(:node, :bar).should == 0
      v.inc(:node, :bar).should == 1
      v.get(:foo).should == 11

      v.reset :foo
      v.get(:foo).should == 0
      v.get(:node, :bar).should == 1

    end

    it 'should allow setting of counters' do
      v.declare_node :node
      v.declare_node :node, 'subnode'
      v.declare_counter :node, 'subnode', 'counter'
      v.set :node, 'subnode', 'counter', 30
      v.get(:node, 'subnode', 'counter').should == 30

      v.inc :node, 'subnode', 'counter'
      v.get(:node, 'subnode', 'counter').should == 31
    end


    describe 'hm-specific metrics' do
      before :each do
        v.prepare
      end

      it 'should return valid hm varz' do
        v.declare_node :running, :frameworks, 'sinatra'
        v.declare_counter :running, :frameworks, 'sinatra', :apps

        v.set :total_apps, 10
        10.times { v.inc :running, :frameworks, 'sinatra', :apps }

        v.get(:total_apps).should == 10
        v.get(:running, :frameworks, 'sinatra', :apps).should == 10
      end

      it 'should have hm metrics once #prepare is called' do
        v.get(:total_apps).should == 0
        v.get(:missing_instances).should == 0

        v.get(:running).should == { :frameworks => {}, :runtimes => {} }
        v.get(:total).should == { :frameworks => {}, :runtimes => {} }
      end

      it 'should update realtime stats according to droplet data' do
        app, _ = make_app({:num_instances => 2})
        v.update_realtime_stats_for_droplet(app)
        v.get(:total_apps).should == 1
        v.get(:running, :frameworks, 'sinatra', :missing_instances) == 2
      end

      describe 'expected stats' do
        it 'should be resettable' do
          v.set(:total, 10)
          v.get(:total).should == 10
          v.reset_expected_stats
          v.held?(:total).should be_true
          v.release_expected_stats
          v.held?(:total).should be_false
        end
      end
    end
  end
end

require 'spec_helper'

describe HealthManager::DesiredState do
  let(:bulk_api_host) { "127.0.0.1" }
  let(:bulk_login) { "bulk_api" }
  let(:bulk_password) { "bulk_password" }
  let(:batch_size) { 2 }

  let(:config) {
    {
      'bulk_api' => {
        'host' => bulk_api_host,
        'batch_size' => batch_size,
      },
      'logging' => {
        'file' => '/dev/null'
      }
    }
  }
  let(:manager) { HealthManager::Manager.new(config) }
  let(:varz) { manager.varz }
  let(:droplet_registry) { manager.droplet_registry }
  let(:provider) { manager.desired_state }

  describe "bulk_url" do
    context "when url starts with https" do
      let(:bulk_api_host) { "https://127.0.0.1" }

      it "starts with https" do
        provider.bulk_url.should eq ("https://127.0.0.1/bulk")
      end
    end

    context "when url starts with http" do
      let(:bulk_api_host) { "http://127.0.0.1" }

      it "starts with http" do
        provider.bulk_url.should eq ("http://127.0.0.1/bulk")
      end
    end

    context "when does not start with http or https" do
      it "starts with http" do
        provider.bulk_url.should eq ("http://127.0.0.1/bulk")
      end
    end
  end

  describe "HTTP requests" do
    before do
      manager.varz.reset_desired!
      provider.stub(:with_credentials).and_yield(bulk_login, bulk_password)
      EM::HttpConnection.any_instance.stub(:get).with(any_args).and_return(http_mock)
    end

    describe "update_user_counts" do
      let(:http_mock) do
        http = double("http")
        http.stub(:response_header).and_return(double("response header"))
        http.response_header.stub(:status).and_return(http_response_status)
        http.stub(:response).and_return(http_response_body)
        http
      end

      let(:http_response_status) { 200 }
      let(:user_count) { 1000 }
      let(:http_response_body) { encode_json({:counts => {:user => user_count}}) }

      subject do
        in_em do
          provider.update_user_counts
          done
        end
      end

      context "http callback successful" do

        before do
          http_mock.should_receive(:callback).and_yield
          http_mock.should_receive(:errback)
        end

        it "should update varz[:total_users] with user counts" do
          varz.should_receive(:[]=).with(:total_users, user_count)
          provider.should_not_receive(:reset_credentials)
          subject
        end

        it 'should be available' do
          subject
          provider.should be_available
        end
      end

      context "http callback with non-200 status" do
        let(:http_response_status) { 500 }
        before do
          http_mock.should_receive(:callback).and_yield
          http_mock.should_receive(:errback)
        end

        it "should not update varz" do
          varz.should_not_receive(:[]=)
          subject
        end

        it "should reset credentials" do
          provider.should_receive(:reset_credentials)
          subject
        end

        it "should become unavailable" do
          subject
          provider.should_not be_available
        end
      end

      context "http errback" do

        before do
          http_mock.should_receive(:callback)
          http_mock.should_receive(:errback).and_yield
        end

        it "should not update varz" do
          varz.should_not_receive(:[]=)
          subject
        end

        it "should reset credentials" do
          provider.should_receive(:reset_credentials)
          subject
        end

        it "should become unavailable" do
          subject
          provider.should_not be_available
        end
      end
    end

    describe "update" do
      let(:bulk_token) { "{}" }
      let(:droplets_received) { [] }
      let(:block) { Proc.new { |app_id, droplet_hash| droplets_received << droplet_hash } }

      let(:http_mock) do
        http = double("http")
        http.stub(:response_header).and_return(double("response header"))
        http.response_header.stub(:status).and_return(http_response_status, http_response_status_alternate)
        http.stub(:response).and_return(http_response_body1, http_response_body2, http_response_body3)
        http
      end

      # This way, the status and response can either be set once for all stubs,
      # or the values can be alternated as required by various flows
      let(:http_response_status_alternate) { http_response_status }

      let(:bulk_hash1) { make_bulk_entry('1') }
      let(:bulk_hash2) { make_bulk_entry('2') }
      let(:bulk_hash3) { make_bulk_entry('3') }

      let(:http_response_status) { 200 }

      let(:http_response_body1) do
        encode_json({"bulk_token" => "fake-token", "results" => {'1' => bulk_hash1, '2' => bulk_hash2}})
      end

      let(:http_response_body2) do
        encode_json({"bulk_token" => "fake-token", "results" => {'3' => bulk_hash3}})
      end

      let(:http_response_body3) { encode_json({"bulk_token" => "fake-token", "results" => {}}) }

      subject do
        in_em do
          provider.update(&block)
          done
        end
      end

      context "when the http request is successful" do
        context "and the http status is not 200" do
          before do
            http_mock.should_receive(:callback).and_yield
            http_mock.should_receive(:errback)
          end
          let(:http_response_status) { 201 }
          let(:http_response_body1) { "" }

          it "should log an error" do
            provider.logger.should_receive(:error)
            subject
          end

          it "should exit the callback" do
            provider.should_receive(:process_next_batch).exactly(:once).and_call_original
            subject
          end

          it 'should become unavailable' do
            subject
            provider.should_not be_available
          end
        end

        context "and there are three entries available" do

          # With the batch size set to '2', and three entries available for retrieval,
          # 3 requests should be made:
          # 1st request returns the first two items;
          # 2nd request returns the last item;
          # 3rd request returns an empty set, signalling the end of retrieval.

          before do
            http_mock.should_receive(:callback).exactly(3).times.and_yield
            http_mock.should_receive(:errback).exactly(3).times
          end

          it "yields the three entries" do
            subject
            expect(droplets_received).to eq([bulk_hash1, bulk_hash2, bulk_hash3])
          end

          it "processes the next batch" do
            provider.should_receive(:process_next_batch).exactly(3).times.and_call_original
            subject
          end

          it "should publish varz stats" do
            varz.should_receive(:publish_desired_stats)
            subject
          end

          it "should log something" do
            provider.logger.should_receive(:info).with /bulk.*done/
            subject
          end

          it 'should be available' do
            subject
            provider.should be_available
          end
        end
      end

      context "when the http request is not successful" do
        context "when the failures are intermittent" do
          let(:http_response_status) { 500 }
          let(:http_response_status_alternate) { 200 }

          before do

            #setup the expectation to call the errback block first, and callback block then.
            flags = double("flags")
            flags.stub("must_succeed").and_return(false, false, true)

            http_mock.should_receive(:callback).exactly(4).times do |&block|
              block.call if flags.must_succeed
            end
            http_mock.should_receive(:errback).exactly(4).times do |&block|
              block.call unless flags.must_succeed
            end
          end

          it "yields the three entries" do
            subject
            expect(droplets_received).to eq([bulk_hash1, bulk_hash2, bulk_hash3])
          end

          it "should publish desired stats" do
            varz.should_receive(:publish_desired_stats).and_call_original
            subject
          end

          it "should log warnings and then success" do
            provider.logger.should_receive(:warn).with(/bulk/).and_call_original
            provider.logger.should_receive(:info).with(/retry/i).ordered.and_call_original
            provider.logger.should_receive(:info).with(/bulk.*done/).ordered.and_call_original
            subject
          end

          it 'should be available' do
            subject
            provider.should be_available
          end
        end

        context "when the failures keep repeating" do
          let(:http_response_status) { 500 }
          before do
            http_mock.should_receive(:callback).exactly(HealthManager::MAX_BULK_ERROR_COUNT).times
            http_mock.should_receive(:errback).exactly(HealthManager::MAX_BULK_ERROR_COUNT).times.and_yield
          end

          it "should not publish desired stats" do
            varz.should_not_receive(:publish_desired_stats)
            subject
          end

          it "should reset credentials" do
            provider.should_receive(:reset_credentials)
            subject
          end

          it "should log warnings and then an error" do
            provider.logger.should_receive(:warn).with(/bulk/).
              exactly(HealthManager::MAX_BULK_ERROR_COUNT).times.and_call_original
            provider.logger.should_receive(:error).with(/bulk/).
              exactly(:once).and_call_original
            subject
          end

          it 'should become unavailable' do
            subject
            provider.should_not be_available
          end
        end
      end
    end

    describe "process_next_batch" do
      let(:http_mock) do
        http = double("http")
        http.stub(:response_header).and_return(double("response header"))
        http.response_header.stub(:status).and_return(http_response_status)
        http.stub(:response).and_return(http_response_body_1, http_response_body_2, "{}")
        http
      end

      let(:droplet_info) do
        {
          "instances" => 1,
          "memory" => 256,
          "state" => "STARTED",
          "version" => "123",
          "package_state" => "STAGED",
          "updated_at" => Time.now
        }
      end

      let(:bulk_token) { "bulk_token" }
      let(:results_1) do
        {
          "1" => droplet_info,
          "2" => droplet_info
        }
      end
      let(:results_2) do
        {
          "3" => droplet_info,
          "4" => droplet_info
        }
      end

      let(:desired_droplets) { ["1", "2", "3", "4"] }
      let(:registered_droplets) { ["0", "1", "2", "5"] }
      let(:removed_droplets) { ["0", "5"] }

      let(:http_response_status) { 200 }
      let(:http_response_body_1) { encode_json({"bulk_token" => bulk_token, "results" => results_1}) }
      let(:http_response_body_2) { encode_json({"bulk_token" => bulk_token, "results" => results_2}) }

      subject do
        in_em do
          provider.process_next_batch(bulk_token)
          done
        end
      end

      before do
        EM::HttpConnection.any_instance.stub(:get).with(any_args).and_return(http_mock)
      end

      context "http callback successful" do
        before do
          http_mock.stub(:callback).and_yield
          http_mock.stub(:errback)
        end

        it "removes droplets from registry that are not in response" do
          registered_droplets.each do |id|
            droplet_registry.get(id)
          end

          subject

          desired_droplets.each do |id|
            expect(droplet_registry.keys).to include(id)
          end

          removed_droplets.each do |id|
            expect(droplet_registry.keys).to_not include(id)
          end
        end
      end
    end
  end

  describe "#with_credentials" do
    before do
      provider.reset_credentials
    end

    context "nats responds" do
      let(:response) {
        encode_json({
                      "user" => "some_user",
                      "password" => "some_password"
                    })
      }
      before do
        NATS.should_receive(:request).once.and_yield(response)
        NATS.should_receive(:timeout).once
      end

      it "requests the credentials from nats" do
        expect { |b| provider.with_credentials(&b) }.to yield_with_args("some_user", "some_password")
      end

      it "does not release the stats" do
        varz.should_not_receive :release_desired!
        provider.with_credentials {}
      end

      it "uses the cached credentials on subsequent calls" do
        # "before" expectations ensure NATS is only called once even for multiple calls
        3.times {
          expect { |b| provider.with_credentials(&b) }.to yield_with_args("some_user", "some_password")
        }
      end
    end

    context "nats times out" do
      before do
        NATS.should_receive(:request)
        NATS.should_receive(:timeout).and_yield
      end

      it "logs the error" do
        logger.should_receive(:error).with(/timeout/)
        provider.with_credentials {}
      end
    end
  end

  describe "#bulk_url" do
    subject { described_class.new(config, varz, droplet_registry) }

    context "with no scheme configured" do
      let(:bulk_api_host) { "api.vcap.me" }

      it "is the config with http://" do
        expect(subject.bulk_url).to eq("http://api.vcap.me/bulk")
      end
    end

    context "with a http scheme" do
      let(:bulk_api_host) { "http://api.vcap.me" }

      it "keeps the http scheme" do
        expect(subject.bulk_url).to eq("http://api.vcap.me/bulk")
      end
    end

    context "with a https scheme" do
      let(:bulk_api_host) { "https://api.vcap.me" }

      it "keeps the https scheme" do
        expect(subject.bulk_url).to eq("https://api.vcap.me/bulk")
      end
    end
  end
end

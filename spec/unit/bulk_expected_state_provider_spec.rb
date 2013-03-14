require 'spec_helper'

describe HealthManager::BulkBasedExpectedStateProvider do
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
    }
  }
  let(:manager) { m = HealthManager::Manager.new(config); m.varz.prepare; m }
  let(:varz) { manager.varz }
  let(:provider) { manager.expected_state_provider }

  describe "HTTP requests" do
    before do
      manager.varz.reset_expected_stats
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
          varz.should_receive(:set).with(:total_users, user_count)
          provider.should_not_receive(:reset_credentials)
          subject
        end
      end

      context "http callback with non-200 status" do
        let(:http_response_status) { 500 }
        before do
          http_mock.should_receive(:callback).and_yield
          http_mock.should_receive(:errback)
        end

        it "should not update varz" do
          varz.should_not_receive(:set)
          subject
        end

        it "should reset credentials" do
          provider.should_receive(:reset_credentials)
          subject
        end
      end

      context "http errback" do

        before do
          http_mock.should_receive(:callback)
          http_mock.should_receive(:errback).and_yield
        end

        it "should not update varz" do
          varz.should_not_receive(:set)
          subject
        end

        it "should reset credentials" do
          provider.should_receive(:reset_credentials)
          subject
        end
      end
    end

    describe "each_droplet" do
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
          provider.each_droplet(&block)
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

          it "should release the stats" do
            varz.should_receive(:release_expected_stats)
            subject
          end

          it "should exit the callback" do
            provider.should_receive(:process_next_batch).exactly(:once).and_call_original
            subject
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
            varz.should_receive(:publish_expected_stats)
            subject
          end

          it "should log something" do
            provider.logger.should_receive(:info).with /bulk.*done/
            subject
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

          it "should publish expected stats" do
            varz.should_receive(:publish_expected_stats).and_call_original
            subject
          end

          it "should log warnings and then success" do
            provider.logger.should_receive(:warn).with(/bulk/).and_call_original
            provider.logger.should_receive(:info).with(/retry/i).ordered.and_call_original
            provider.logger.should_receive(:info).with(/bulk.*done/).ordered.and_call_original
            subject
          end
        end

        context "when the failures keep repeating" do
          let(:http_response_status) { 500 }
          before do
            http_mock.should_receive(:callback).exactly(HealthManager::MAX_BULK_ERROR_COUNT).times
            http_mock.should_receive(:errback).exactly(HealthManager::MAX_BULK_ERROR_COUNT).times.and_yield
          end

          it "should not publish expected stats" do
            varz.should_not_receive(:publish_expected_stats)
            subject
          end

          it "should release varz" do
            varz.should_receive(:release_expected_stats)
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
        varz.should_not_receive :release_expected_stats
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

      it "releases the stats when the expected stats are held" do
        varz.stub(:expected_stats_held? => true)

        varz.should_receive :release_expected_stats
        provider.with_credentials {}
      end

      it "does not release the stats when the expected stats are not held" do
        varz.stub(:expected_stats_held? => false)

        varz.should_not_receive :release_expected_stats
        provider.with_credentials {}
      end
    end
  end
end

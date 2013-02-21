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

  subject { manager.expected_state_provider }

  it "should be instantiated with the proper config" do
    subject
  end

  describe "each_droplet" do
    let(:bulk_token) { "{}" }
    let(:droplets_received) { [] }
    let(:block) { Proc.new { |app_id, droplet_hash| droplets_received << droplet_hash } }

    let(:provider) { manager.expected_state_provider }
    let(:http_mock) do
      http = double("http")
      http.stub(:response_header).and_return(double("response header"))
      http.response_header.stub(:status).and_return(http_response_status, http_response_status_alternate)
      http.stub(:response).and_return(http_response_body1, http_response_body2, http_response_body3 )
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
      encode_json({"bulk_token" => "fake-token", "results" => { '1' => bulk_hash1, '2' => bulk_hash2 }})
    end

    let(:http_response_body2) do
      encode_json({"bulk_token" => "fake-token", "results" => { '3' => bulk_hash3 }})
    end

    let(:http_response_body3) { encode_json({"bulk_token" => "fake-token", "results" => {}}) }

    subject do
      in_em do
        provider.each_droplet(&block)
        done
      end
    end

    before do
      manager.varz.reset_expected_stats
      provider.stub(:with_credentials).and_yield(bulk_login, bulk_password)

      EM::HttpConnection.any_instance.stub(:get).with(any_args).and_return(http_mock)
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
          expect(droplets_received).to eq([ bulk_hash1, bulk_hash2, bulk_hash3 ])
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
          expect(droplets_received).to eq([ bulk_hash1, bulk_hash2, bulk_hash3 ])
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

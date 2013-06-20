require "spec_helper"

describe HealthManager::Config do

  let(:input_hash) do
    {}
  end

  describe "load" do
    let(:input_hash) do
      {
        :first_field => 1,
        "second_field" => 2,
        "third_field" => {
          "inner_level" => 3
        }
      }
    end

    it "symbolizes every key" do
      HealthManager::Config.load(input_hash)
      expect(HealthManager::Config.config[:first_field]).to eq 1
      expect(HealthManager::Config.config[:second_field]).to eq 2
      expect(HealthManager::Config.config["second_field"]).to be_nil
      expect(HealthManager::Config.config[:third_field][:inner_level]).to eq 3
    end
  end


  describe "get_param" do

    let(:input_hash) do
      { :some_field => "some value" }
    end

    before do
      stub_const("HealthManager::DEFAULTS",
        {
          :other_field => "default value"
        })

      HealthManager::Config.load(input_hash)
    end

    context "when input includes the given field" do
      it "returns the input configuration" do
        expect(HealthManager::Config.get_param(:some_field)).to eq "some value"
      end
    end

    context "when the input does not include the given field" do
      it "gets a value from the defaults" do
        expect(HealthManager::Config.get_param(:other_field)).to eq "default value"
      end
    end

    context "when there is no default for the requested field" do
      it "raises an ArgumentError" do
        expect{HealthManager::Config.get_param(:missing_field)}.to raise_error(ArgumentError)
      end
    end
  end

  describe "interval" do
    let(:interval_from_default) { :min_restart_delay }
    let(:interval_from_input) { :flapping_timeout }
    let(:missing_interval) { :missing }

    let(:input_hash) do
      {
        :intervals => {
          interval_from_input => 500
        }
      }
    end

    before do
      stub_const("HealthManager::DEFAULTS",
        {
          :intervals => {
            interval_from_default => 30
          }
        }
      )
      HealthManager::Config.load(input_hash)
    end

    context "when the interval is provided by the input hash" do
      it "returns the input configuration" do
        expect(HealthManager::Config.interval(interval_from_input)).to eq 500
      end
    end

    context "when the specific interval is not provided by the input hash" do
      it "gets the value from the defaults" do
        expect(HealthManager::Config.interval(interval_from_default)).to eq 30
      end
    end

    context "when NO intervals are provided by the input hash" do
      let(:input_hash) { {} }
      it "gets the value from the defaults" do
        expect(HealthManager::Config.interval(interval_from_default)).to eq 30
      end
    end

    context "when there is no default for the requested interval" do
      it "raises an ArgumentError" do
        expect{HealthManager::Config.interval(missing_interval)}.to raise_error(ArgumentError)
      end
    end
  end

  describe "bulk_api_url" do
    before do
      HealthManager::Config.load(input_hash)
    end

    context "when the bulk api is provided by the input hash" do
      let(:input_hash) do
        {
          bulk_api: {
            host: "api.tabasco.cf-app.com"
          }
        }
      end

      it "returns the input configuration" do
        expect(HealthManager::Config.bulk_api_url).to eq "api.tabasco.cf-app.com"
      end
    end

    context "when the bulk api is not provided" do
      let(:input_hash) { {} }

      it "raises an ArgumentError" do
        expect{HealthManager::Config.bulk_api_url}.to raise_error(ArgumentError)
      end
    end
  end

  describe "logging_config" do
    context "when level is provided in input hash" do
      let(:input_hash) do
        {
          logging: {
            level: "debug"
          }
        }
      end

      before { HealthManager::Config.load(input_hash) }

      it "returns the input configuration" do
        expect(HealthManager::Config.logging_config[:level]).to eq "debug"
      end
    end

    context "when level is provided in environment variable" do
      before do
        ENV["LOG_LEVEL"] = "level_from_env"
        HealthManager::Config.load(input_hash)
      end

      after { ENV.delete("LOG_LEVEL") }

      let(:input_hash) { {} }

      it "returns the environment variable" do
        expect(HealthManager::Config.logging_config[:level]).to eq "level_from_env"
      end
    end

    context "when the level is not provided" do
      let(:input_hash) { {} }
      before { HealthManager::Config.load(input_hash) }

      it "defaults to 'info'" do
        expect(HealthManager::Config.logging_config[:level]).to eq "info"
      end
    end
  end

  describe "mbus_url" do
    before do
      HealthManager::Config.load(input_hash)
    end

    context "when the mbus is provided by the input hash" do
      let(:input_hash) do
        {
          mbus: "nats://nats:nats@127.0.0.1:4222"
        }
      end

      it "returns the input configuration" do
        expect(HealthManager::Config.mbus_url).to eq "nats://nats:nats@127.0.0.1:4222"
      end
    end

    context "when the mbus is not provided" do
      let(:input_hash) { {} }

      it "raises an ArgumentError" do
        expect{HealthManager::Config.mbus_url}.to raise_error(ArgumentError)
      end
    end
  end

  describe "status_config" do
    context "when the status config is provided in input hash" do
      let(:input_hash) do
        {
          status: {
            user: "varz"
          }
        }
      end

      before { HealthManager::Config.load(input_hash) }

      it "returns the input configuration" do
        expect(HealthManager::Config.status_config[:user]).to eq "varz"
      end
    end

    context "when the status config is not provided" do
      let(:input_hash) { {} }
      before { HealthManager::Config.load(input_hash) }

      it "defaults to an empty hash" do
        expect(HealthManager::Config.status_config[:port]).to be_nil
      end
    end
  end

  describe "bulk_api_batch_size" do
    context "when the batch_size is provided in input hash" do
      let(:input_hash) do
        {
          bulk_api: {
            host: "api.tabasco.cf-app.com:80",
            batch_size: "100"
          }
        }
      end

      before { HealthManager::Config.load(input_hash) }

      it "returns the input configuration" do
        expect(HealthManager::Config.bulk_api_batch_size).to eq "100"
      end
    end

    context "when the status config is not provided" do
      let(:input_hash) { {} }
      before { HealthManager::Config.load(input_hash) }

      it "defaults to 500" do
        expect(HealthManager::Config.bulk_api_batch_size).to eq "500"
      end
    end
  end
end
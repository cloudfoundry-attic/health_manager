#!/usr/bin/env ruby

require "thin"
require "yajl"
require "sinatra/base"
require "nats/client"

PORT = ARGV[0]
USERNAME = ARGV[1]
PASSWORD = ARGV[2]
NATS_PORT = ARGV[3]

class FakeBulkApi < Sinatra::Base
  def initialize(apps_json)
    super
    @apps_json = apps_json
  end

  use Rack::Auth::Basic, "Restricted Area" do |given_username, given_password|
    USERNAME == given_username && PASSWORD == given_password
  end

  get "/bulk/apps" do
    token = Yajl::Parser.parse(params['bulk_token'])
    if token == "done!"
      respond_json({})
    else
      respond_json(@apps_json.merge('bulk_token' => 'done!'))
    end
  end

  get "/bulk/counts" do
    respond_json({:counts => {:app => @apps_json['results'].size, :user => 42}})
  end

  private

  def respond_json(response)
    content_type :json
    Yajl::Encoder.encode(response, :pretty => true, :terminator => "\n")
  end
end

$stdout.sync = true

apps_json = {
  "results" => {
    "app-id1" => {
      "instances" => 2,
      "state" => "STARTED",
      "version" => "some-version-app-id1",
      "package_state" => "STAGED",
      "updated_at" => Time.now.to_s,
      "memory" => 256
    },
    "app-id2" => {
      "instances" => 3,
      "state" => "STARTED",
      "version" => "some-version-app-id2",
      "package_state" => "STAGED",
      "updated_at" => Time.now.to_s,
      "memory" => 512
    }
  }
}

thin_pid = fork do
  Rack::Handler::Thin.run(FakeBulkApi.new(apps_json), :Port => PORT)
end

at_exit do
  puts "stopping fake bulk API"
  Process.kill("TERM", thin_pid)
end

NATS.on_error do
  puts "can't connect to NATS"
end

NATS.start(:uri => "nats://localhost:#{NATS_PORT}", :max_reconnect_attempts => Float::INFINITY) do
  NATS.subscribe("cloudcontroller.bulk.credentials.default") do |_, reply|
    NATS.publish(reply, Yajl::Encoder.encode({ :user => USERNAME, :password => PASSWORD }))
  end
end

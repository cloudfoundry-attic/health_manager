require 'cgi'
require 'thin'
require 'nats/client'
require 'pp'
require 'yaml'
require 'yajl'

# simulates "the world" for hm_next for the pursposes of performance testing etc.

<<EOL

- setup the world:
  - number of apps
  - number of deas
  - fraction of crashing apps; crash rate
  - activity rate: how often apps are stopped/started/updated

- run the world:
  - start NATs (meh, assume it's running)
  - decide which apps are up, "spread" them over "deas"
  - publish h/b
  - generate and publish events like crashes, stop/starts, updates
  - maintain bulk api to the desired state

EOL

HEARTBEAT_INTERVAL = 10

@config = {
  :apps_number => 10000,
  :instance_per_app => 2,
  :dea_number => 200,
  :crashing_apps_number => 200,
  :crash_ratio => 120, #every app designated as crashing crashes with at random period with expectation X seconds
  :activity_rate => 10, # a random app is randomly updated at random period with expectation X seconds
}



@world = {
  :config => @config,
  :apps => Array.new(@config[:apps_number]),
  :deas => [],
}

def say(*args)
  puts(*args)
end

def expect_positive_integer_at(expectation)
  1 + rand(expectation * 2 - 1)
end

def make_hash(len = 24)
  (0...len).map {rand(16).to_s(16)}.join
end

def create_dea(dea_id)
  {
    :id => "dea_#{dea_id}",
    :instances => []
  }
end

def make_heartbeat(dea)
  {
    :dea => dea[:id],
    :prod => false,
    :droplets => dea[:instances],
  }
end

def create_app(app_id, config)
  {
    :id => app_id,
    :instances => [],
    'memory' => 128,
    # "desired state" stuff
    'instances' => expect_positive_integer_at(config[:instance_per_app]),
    'state' => 'STARTED',
    'staged_package_hash' => make_hash,
    'run_count' => 1,
    'package_state' => 'STAGED',
    'updated_at' => (Time.now - 3600).to_s
  }
end

def create_instance(app, index, dea_id)
  {
    :droplet => app[:id],
    :index => index,
    :version => "#{app['staged_package_hash']}-#{app['run_count']}",
    :instance => make_hash,
    :state => 'RUNNING',
    :state_timestamp => Time.now.to_i - 3600,
    :cc_partition => 'default',
    :dea_id => dea_id
  }
end

def place_instance_into_dea(app, index, dea)
  instance = create_instance(app, index, dea[:id])
  dea[:instances] << instance
  app[:instances] << instance
end

def populate_world(config, world)

  say "populating world..."

  dea_number = config[:dea_number]
  say "creating #{dea_number} deas"
  dea_number.times do |dea_id|
    world[:deas] << create_dea(dea_id)
  end

  app_number = config[:apps_number]
  say "creating #{app_number} apps"
  app_number.times do |app_id|
    world[:apps][app_id] = create_app(app_id, config)
  end

  crashing_num = config[:crashing_apps_number]
  say "marking #{crashing_num} apps as crashing"
  crasher_ids = world[:crasher_ids] = (0...app_number).to_a.shuffle[0...crashing_num]
  crasher_ids.each do |crasher_id|
    world[:apps][crasher_id][:crasher] = true
  end

  dea_cycle = world[:deas].cycle

  world[:apps].each do |app|
    app['instances'].times {|index|
      place_instance_into_dea(app, index, dea_cycle.next)
    }
  end
  say world.to_yaml
end

def bail
  say "interrupted, exiting"
  NATS.stop { EM.stop }
  exit 0
end

def parse_json(v)
  Yajl::Parser.parse(v)
end

def to_json(v)
  Yajl::Encoder.encode(v)
end

class BaseResponder
  def initialize(world)
    @apps = world[:apps]
  end

  def parse_params(env)
    params = {}

    env['QUERY_STRING'].split("&").each do |pair|
      k,v = pair.split("=")
      params[k] = Yajl::Parser.parse(CGI::unescape(v))
    end
    params
  end

  def respond_json(response)
    response = Yajl::Encoder.encode(response, :pretty => true, :terminator => "\n")
    [200, { 'Content-Type' => 'application/json', 'Content-Length' => response.length.to_s }, response ]
  end
end

class Counter < BaseResponder
  def call(env)
    respond_json( :counts => { 'app' => @apps.size, 'user' => 1 } )
  end
end

class BulkApi < BaseResponder
  BATCH_SIZE = 5

  def make_batch(apps)
    result = {}

    apps.each do |app|
      result[app[:id]] = app
    end
    result
  end

  def make_token(batch)
    batch.empty? ? {} : {:id => batch.keys.max }
  end

  def get_min_id(env)
    bulk_token = parse_params(env)['bulk_token'] || {}
    (bulk_token['id'] || -1).to_i + 1
  end

  def get_apps(env)
    min_id = get_min_id(env)
    batch_size = (parse_params(env)['batch_size'] || BATCH_SIZE).to_i

    max_id = min_id + batch_size
    max_id = @apps.size if max_id > @apps.size
    (min_id...max_id).map { |i| @apps[i] }
  end

  def call(env)
    apps = get_apps(env)
    batch = make_batch(apps)
    token = make_token(batch)
    response = {:results => batch, :bulk_token => token }
    respond_json(response)
  end
end


def setup_bulk_api_server(world, cc_partition = 'default')

  host = '192.168.24.128'
  port = 5555
  auth = { :user => 'bulk_api', :password => 'woohoo1234'}

  NATS.subscribe("cloudcontroller.bulk.credentials.#{cc_partition}") do |_, reply|
    NATS.publish(reply, to_json(auth))
  end

  http_server = Thin::Server.new(host, port, :signals => false) do
    # Thin::Logging.silent = true
    use Rack::Auth::Basic do |user, password|
      auth[:user] == user && auth[:password] == password
    end

    map '/bulk/apps' do
      run BulkApi.new(world)
    end

    map '/bulk/counts/' do
      run Counter.new(world)
    end
  end
  http_server.start!
end

def setup_heartbeats(world)
  world[:deas].each do |dea|
    EM.add_timer( 5 * rand ) do
      EM.add_periodic_timer(HEARTBEAT_INTERVAL) do
        NATS.publish('dea.heartbeat', to_json(make_heartbeat(dea)))
      end
    end
  end
end

def setup_crash_for_app(world, crasher_id, expected_time_to_crash)

  EM.add_timer(2*expected_time_to_crash*rand) do
    app = world[:apps][crasher_id]
    running = app[:instances].select {|instance|
      instance[:state] == 'RUNNING'
    }

    if running.empty?
      say "no more running instances for #{crasher_id}"
    else
      crasher = running[rand(running.size)]
      say "crashing instance #{crasher_id}:#{crasher[:index]}"
      crasher[:state] = 'CRASHED'
      message = {}
      [:droplet, :index, :version, :instance, :cc_partition].each {|k|
        message[k] = crasher[k]
      }
      message[:reason] = 'CRASHED'
      message[:crash_timestamp] = Time.now.to_i
      NATS.publish('droplet.exited', to_json(message))
    end

    #setup next crash
    setup_crash_for_app(world, crasher_id, expected_time_to_crash)
  end
end

def setup_crashes(world)
  world[:crasher_ids].each { |crasher_id|
    setup_crash_for_app(world, crasher_id, world[:config][:crash_ratio])
  }
end

def listen_to_hm(world, cc_partition = 'default')
  NATS.subscribe("cloudcontrollers.hm.requests.#{cc_partition}") do |message|
    message = parse_json(message)
    if message['op'] == 'START'
      app = world[:apps][message['droplet']]
      indices = message['indices']
      say "Restarting #{app[:id]}:#{indices}"
      indices.each { |i|
        instance = app[:instances][i]
        if instance
          instance[:state] = 'RUNNING'
          instance[:instance] = make_hash
        else
          say "Missing instance for index: #{i}"
        end
      }
    else
      raise "Don't know how to interpret this message: #{message}"
    end
  end
end

trap('INT') { bail }
trap('SIGTERM') { bail }

populate_world(@config, @world)

say "connecting to NATS"

EM.epoll

NATS.start :uri => ENV['NATS_URI'] || "nats://nats:nats@192.168.24.128:4223" do

  setup_bulk_api_server(@world)
  setup_heartbeats(@world)
  setup_crashes(@world)
  #setup_update(@world)
  listen_to_hm(@world)

end


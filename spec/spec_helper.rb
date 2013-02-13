# Copyright (c) 2009-2012 VMware, Inc.
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'rspec'
require 'bundler/setup'

require 'health_manager'
require 'timecop'

support_dir = File.join(File.dirname(__FILE__),"support")
Dir["#{support_dir}/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
  config.include(HealthManager::Common)

  config.before :all do
    logging_config = { 'level' => ENV['LOG_LEVEL'] || 'fatal' }
    steno_config = Steno::Config.to_config_hash(logging_config)
    steno_config[:context] = Steno::Context::ThreadLocal.new
    Steno.init(Steno::Config.new(steno_config))
  end
end

# Copyright (c) 2009-2012 VMware, Inc.
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'rspec'
require 'bundler/setup'

require 'health_manager'

support_dir = File.join(File.dirname(__FILE__),"support")
Dir["#{support_dir}/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
 config.include(HealthManager)
end



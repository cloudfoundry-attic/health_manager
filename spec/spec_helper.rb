# Copyright (c) 2009-2012 VMware, Inc.
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

home = File.join(File.dirname(__FILE__), '..')
ENV['BUNDLE_GEMFILE'] = "#{home}/Gemfile"

require 'rubygems'
require 'rspec'
require 'bundler/setup'

require 'health_manager'

RSpec.configure do |config|
 config.include(HealthManager)
end

Dir["#{home}/spec/support/**/*.rb"].each { |f| require f }

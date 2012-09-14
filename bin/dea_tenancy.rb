require File.join(File.dirname(__FILE__),'..','lib','health_manager')

require 'pp'

@tiers = {}

compact = false

def showem
  puts "DEA Tenancy.  Tier count: #{@tiers.size}  #{Time.now}"
  @tiers.keys.sort.each do |tier|
    deas = @tiers[tier]
    puts "Tier: #{tier}, Size: #{deas.size} deas"
    deas.keys.sort.each { |dea|
      droplets = deas[dea]
      puts "  #{dea}"
      puts "     #{droplets.inspect}"
    }
  end
end

def showem_and_stop
  showem
  NATS.stop
end

['INT','SIGTERM'].each {|sig| trap(sig) { NATS.stop }}

NATS.start :uri => ENV['NATS_URI'] do

  NATS.subscribe('dea.heartbeat') do |json|

    msg = Yajl::Parser.parse(json)

    dea = msg['dea']
    tier = msg['tier'] || "DEFAULT"
    deas = @tiers[tier] ||= {}
    enough = deas.has_key? dea

    if compact
      deas[dea] = msg['droplets'].inject(Hash.new(0)) do |h,d|
        h[d['state']] += 1
        h
      end
    else
      deas[dea] = msg['droplets'].map { |d|
        #puts d
        klass_letter = d['droplet'].class.to_s[0].downcase
        "#{d['state'][0]}:#{d['droplet']}#{klass_letter}:#{d['index']}@#{d['cc_partition']}"
      }
    end


    showem_and_stop if enough
  end
end




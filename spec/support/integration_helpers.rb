require "httparty"

module IntegrationHelpers
  def startup_health_manager
    @hm_pid = run_cmd("./bin/health_manager", debug: false)

    Timeout::timeout(10) do
      loop do
        sleep 0.2
        begin
          result = HTTParty.get(
            "http://127.0.0.1:54321/varz",
            basic_auth: { username: "thin", password: "thin" }
          )
          break if result.success?
        rescue Errno::ECONNREFUSED => e
          # puts "rescued and retrying from #{e}"
        end
      end
    end
  end

  def with_nats_server(timeout = 10)
    @nats_pid = run_cmd("nats-server -D", debug: false)
    wait_until_nats_available
    NATS.start do
      EM.add_timer(timeout) do
        puts "Timeout reached, exiting..."
        NATS.stop
      end
      yield
    end
  ensure
    graceful_shutdown(:nats, @nats_pid)
  end

  def done_with_nats
    raise "NATS not connected" unless NATS.connected?
    NATS.stop
  end

  def wait_until_nats_available
    Timeout::timeout(10) do
      loop do
        begin
          NATS.start do
            # NATS is available! done!
            NATS.stop
            return
          end
        rescue NATS::ConnectError
          #puts "NATS wait: retrying in 0.2 secs"
          sleep 0.2
        end
      end
    end
  end

  def run_cmd(cmd, opts={})
    spawn_opts = {
      :chdir => File.join(File.dirname(__FILE__), "../.."),
      :out => opts[:debug] ? :out : "/dev/null",
      :err => opts[:debug] ? :out : "/dev/null",
    }

    Process.spawn(cmd, spawn_opts).tap do |pid|
      if opts[:wait]
        Process.wait(pid)
        raise "`#{cmd}` exited with #{$?}" unless $?.success?
      end
    end
  end

  def graceful_shutdown(name, pid)
    Process.kill("TERM", pid)
    Timeout.timeout(1) do
      while process_alive?(pid) do
      end
    end
  rescue Timeout::Error
    Process.kill("KILL", pid)
  end

  def process_alive?(pid)
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end
end

RSpec.configure do |rspec_config|
  rspec_config.include(IntegrationHelpers, :type => :integration)
end

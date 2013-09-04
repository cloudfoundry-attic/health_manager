module HealthManager
  class FakeScheduler
    include HealthManager::Common

    attr_reader :now

    def initialize(message_bus)
      @now = 1 #time starts at 1 to avoid weird edge conditions with 0
      @single_blocks = []
      @periodic_blocks = []
      @receipt_counter = 0
      @starting_times = {}

      message_bus.subscribe('healthmanager.advance_time') do |msg, reply_to|
        time = Time.new
        advance_time(msg.fetch(:seconds))
        message_bus.publish(reply_to, {:seconds => msg.fetch(:seconds)})
      end
    end

    def start
    end

    def advance_time(seconds)
      seconds.times do |_|
        @now += 1
        check_periodic_blocks
        check_single_blocks
      end
    end

    def at_interval(interval_name, &block)
      @periodic_blocks << {
        last_run: @now,
        block: block,
        period: interval(interval_name)
      }
    end

    def after(interval, &block)
      receipt = @receipt_counter
      @receipt_counter = @receipt_counter + 1

      @single_blocks <<  {
        block: block,
        time: interval + @now,
        receipt: receipt
      }

      receipt
    end

    def immediately(&block)
      block.call()
    end

    def set_start_time(task)
      @starting_times[task] = @now
    end

    def elapsed_time(task)
      @now - @starting_times[task]
    end

    def cancel(receipt)
      @single_blocks.reject! do |single_block|
        single_block[:receipt] == receipt
      end
    end

    private

    def check_periodic_blocks
      @periodic_blocks.each do |periodic_block|
        if @now - periodic_block[:last_run] >= periodic_block[:period]
          periodic_block[:block].call()
          periodic_block[:last_run] = @now
        end
      end
    end

    def check_single_blocks
      @single_blocks.each do |single_block|
        if single_block[:time] <= @now
          single_block[:block].call()
        end
      end

      @single_blocks = @single_blocks.reject do |single_block|
        single_block[:time] <= @now
      end
    end
  end
end

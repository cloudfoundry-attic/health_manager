# This class describes in a declarative manner the policy that
# HealthManager is implementing.  It describes a set of rules that
# recognize certain conditions (e.g. missing instances, etc) and
# initiates certain actions (e.g. restarting the missing instances)

module HealthManager
  class Harmonizer
    include HealthManager::Common

    attr_reader :varz, :nudger, :scheduler, :actual_state, :desired_state

    def initialize(varz, nudger, scheduler, actual_state, desired_state, droplet_registry)
      @varz = varz
      @nudger = nudger
      @scheduler = scheduler
      @actual_state = actual_state
      actual_state.harmonizer = self
      @desired_state = desired_state
      @droplet_registry = droplet_registry
      @current_analysis_slice = 0
    end

    def prepare
      logger.debug { "harmonizer: #prepare" }

      #schedule time-based actions

      scheduler.immediately { update_desired_state }

      scheduler.at_interval :request_queue do
        nudger.deque_batch_of_requests
      end

      scheduler.at_interval :desired_state_update do
        update_desired_state
      end

      scheduler.at_interval :droplets_analysis do
        analyze_apps
      end

      scheduler.at_interval :droplet_gc do
        gc_droplets
      end
    end

    def on_droplet_updated(droplet, message)
      logger.info { "harmonizer: droplet_updated: #{message}" }
      droplet.desired_state_update_required = true
      abort_all_pending_delayed_restarts(droplet)
      update_desired_state
    end

    def on_exit_crashed(droplet, message)
      logger.debug { "harmonizer: exit_crashed" }

      index = message.fetch(:index)
      instance = droplet.get_instance(message.fetch(:index), message.fetch(:version))

      if instance.flapping?
        execute_flapping_policy(droplet, instance, true)
      else
        nudger.start_instance(droplet, index, LOW_PRIORITY)
      end
    end

    def on_exit_stopped(message)
      logger.info { "harmonizer: exit_stopped: #{message}" }
    end

    def on_exit_dea(droplet, message)
      index = message.fetch(:index)

      logger.info { "harmonizer: exit_dea: app_id=#{droplet.id} index=#{index}" }
      nudger.start_instance(droplet, index, HIGH_PRIORITY)
    end

    def on_missing_instances(droplet)
      unless actual_state.available?
        logger.warn "harmonizer.actual-state.unavailable"
        return
      end

      return if droplet.desired_state_update_required?

      logger.debug "harmonizer.missing-instances.processing"
      droplet.missing_indices.each do |index|
        instance = droplet.get_instance(index)
        if instance.flapping?
          execute_flapping_policy(droplet, instance, false)
        else
          nudger.start_instance(droplet, index, NORMAL_PRIORITY)
        end
      end
    end

    def on_extra_instances(droplet, extra_instances)
      return if extra_instances.empty?

      if droplet.desired_state_update_required?
        logger.info("harmonizer.desired_state_update_required.extra_instances_ignored", extra_instances)
        return
      end

      logger.info("harmonizer.extra_instances", extra_instances)
      nudger.stop_instances_immediately(droplet, extra_instances)
    end

    def on_extra_app(droplet)
      return unless desired_state.available?

      instances = droplet.all_starting_or_running_instances.inject({}) do |memo, instance|
        memo[instance.guid] = {
          version: instance.version,
          reason: "Extra app",
        }
        memo
      end
      nudger.stop_instances_immediately(droplet, instances)
    end

    # ------------------------------------------------------------
    # Flapping-related code STARTS

    # TODO: consider refactoring. There are some unpleasant
    # abstraction leaks, e.g. calculations involving number of
    # crashes, predicate methods, etc.  Consider making "instance"
    # into a full-fledged object

    def execute_flapping_policy(droplet, instance, chatty)
      unless instance.pending_restart?
        if instance.giveup_restarting?
          logger.info { "given up on restarting: app_id=#{droplet.id} index=#{instance.index}" } if chatty
        else
          delay = calculate_delay(instance)
          schedule_delayed_restart(droplet, instance, instance.index, delay)
        end
      end
    end

    def calculate_delay(instance)
      # once the number of crashes exceeds the value of
      # :flapping_death interval, delay starts with min_restart_delay
      # interval value, and doubles for every additional crash.  the
      # delay never exceeds :max_restart_delay though.  But wait,
      # there's more: random noise is added to the delay, to avoid a
      # storm of simultaneous restarts. This is necessary because
      # delayed restarts bypass nudger's queue -- once delay period
      # passes, the start message is published immediately.

      delay = [interval(:max_restart_delay),
               interval(:min_restart_delay) << (instance.crash_count - interval(:flapping_death) - 1)
              ].min.to_f
      noise_amount = 2.0 * (rand - 0.5) * interval(:delay_time_noise).to_f

      result = delay + noise_amount

      logger.info("delay: #{delay} noise: #{noise_amount} result: #{result}")
      result
    end

    def schedule_delayed_restart(droplet, instance, index, delay)
      receipt = scheduler.after(delay) do
        instance.unmark_pending_restart!
        nudger.start_flapping_instance_immediately(droplet, index)
      end
      instance.mark_pending_restart_with_receipt!(receipt)
    end

    def abort_all_pending_delayed_restarts(droplet)
      droplet.pending_restarts.each do |instance|
        scheduler.cancel(instance.pending_restart_receipt)
        instance.unmark_pending_restart!
      end
    end

    # Flapping-related code ENDS
    # ------------------------------------------------------------

    def gc_droplets
      before = @droplet_registry.size
      @droplet_registry.delete_if { |_,d| d.ripe_for_gc? }
      after = @droplet_registry.size
      logger.info("harmonizer: droplet GC ran. Number of droplets before: #{before}, after: #{after}. #{before-after} droplets removed")
    end

    def analyze_apps
      unless desired_state.available?
        logger.warn("Droplet analysis interrupted. Desired state is not available")
        return
      end

      if @current_analysis_slice == 0
        scheduler.set_start_time(:droplets_analysis)
        logger.debug { "harmonizer: droplets_analysis" }
        varz.reset_realtime!
      end

      droplets_analysis_for_slice
    end

    def update_desired_state
      desired_state.update_user_counts
      varz.reset_desired!
      desired_state.update
    end

    def analyze_droplet(droplet)
      on_extra_app(droplet) if droplet.is_extra?

      if droplet.has_missing_indices?
        on_missing_instances(droplet)
        droplet.reset_missing_indices
      end

      droplet.update_extra_instances
      on_extra_instances(droplet, droplet.extra_instances)

      droplet.prune_crashes
    end

    private

    def finish_droplet_analysis
      elapsed = scheduler.elapsed_time(:droplets_analysis)
      varz[:analysis_loop_duration] = elapsed
      varz.publish_realtime_stats

      logger.info ["harmonizer: Analyzed #{varz[:running_instances]} running ",
        "#{varz[:missing_instances]} missing instances. ",
        "Elapsed time: #{elapsed}"
      ].join
    end

    def droplets_analysis_for_slice
      droplets_analyzed_per_iteration = Config.get_param(:number_of_droplets_analyzed_per_analysis_iteration)
      droplets = @droplet_registry.values.slice(@current_analysis_slice, droplets_analyzed_per_iteration)

      if droplets && droplets.any?
        droplets.each do |droplet|
          analyze_droplet(droplet)
          droplet.update_realtime_varz(varz)
        end
      end

      @current_analysis_slice += droplets_analyzed_per_iteration

      if droplets.nil? || droplets.size < droplets_analyzed_per_iteration
        @current_analysis_slice = 0
        finish_droplet_analysis
      end
    end
  end
end

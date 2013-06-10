# This class describes in a declarative manner the policy that
# HealthManager is implementing.  It describes a set of rules that
# recognize certain conditions (e.g. missing instances, etc) and
# initiates certain actions (e.g. restarting the missing instances)

module HealthManager
  class Harmonizer
    include HealthManager::Common

    attr_reader :varz, :nudger, :scheduler, :actual_state, :desired_state

    def initialize(config, varz, nudger, scheduler, actual_state, desired_state, droplet_registry)
      @config = config
      @varz = varz
      @nudger = nudger
      @scheduler = scheduler
      @actual_state = actual_state
      @desired_state = desired_state
      @droplet_registry = droplet_registry
    end

    def add_logger_listener(event)
      AppState.add_listener(event) do |*args|
        logger.debug { "app_state: event: #{event}: #{args}" }
      end
    end

    def prepare
      logger.debug { "harmonizer: #prepare" }

      #set system-wide configurations
      AppState.heartbeat_deadline = interval(:droplet_lost)
      AppState.desired_state_update_deadline = interval(:desired_state_lost)
      AppState.flapping_timeout = interval(:flapping_timeout)
      AppState.flapping_death = interval(:flapping_death)
      AppState.droplet_gc_grace_period = interval(:droplet_gc_grace_period)

      AppState.add_listener(:extra_app) do |app_state|
        on_extra_app(app_state)
      end

      #set up listeners for anomalous events to respond with correcting actions
      AppState.add_listener(:missing_instances) do |app_state, missing_indices|
        unless actual_state.available?
          logger.info { "harmonizer: actual state was not available." }
          next
        end

        if app_state.desired_state_update_required?
          logger.info { "harmonizer: desired_state_update_required: missing_instances ignored app_id=#{app_state.id} indices=#{missing_indices}" }
          next
        end

        logger.debug { "harmonizer: missing_instances"}
        missing_indices.each do |index|
          instance = app_state.get_instance(index)
          if flapping?(instance)
            execute_flapping_policy(app_state, index, instance, false)
          else
            nudger.start_instance(app_state, index, NORMAL_PRIORITY)
          end
        end
      end

      AppState.add_listener(:extra_instances) do |app_state, extra_instances|
        if app_state.desired_state_update_required?
          logger.info { "harmonizer: desired_state_update_required: extra_instances ignored: #{extra_instances}" }
          next
        end

        logger.debug { "harmonizer: extra_instances"}
        nudger.stop_instances_immediately(app_state, extra_instances)
      end

      AppState.add_listener(:exit_dea) do |app_state, message|
        index = message['index']

        logger.info { "harmonizer: exit_dea: app_id=#{app_state.id} index=#{index}" }
        nudger.start_instance(app_state, index, HIGH_PRIORITY)
      end

      AppState.add_listener(:exit_crashed) do |app_state, message|
        logger.debug { "harmonizer: exit_crashed" }

        index = message['index']
        instance = app_state.get_instance(message['version'], message['index'])

        if flapping?(instance)
          execute_flapping_policy(app_state, index, instance, true)
        else
          nudger.start_instance(app_state, index, LOW_PRIORITY)
        end
      end

      AppState.add_listener(:exit_stopped) do |app_state, message|
        logger.info { "harmonizer: exit_stopped: #{message}" }
        # NOOP
      end

      AppState.add_listener(:droplet_updated) do |app_state, message|
        logger.info { "harmonizer: droplet_updated: #{message}" }
        app_state.desired_state_update_required = true
        abort_all_pending_delayed_restarts(app_state)
        update_desired_state
      end

      #schedule time-based actions

      scheduler.immediately { update_desired_state }

      scheduler.at_interval :request_queue do
        nudger.deque_batch_of_requests
      end

      scheduler.at_interval :desired_state_update do
        update_desired_state
      end

      scheduler.after_interval :droplet_lost do
        scheduler.at_interval :droplets_analysis do
          analyze_all_apps
        end
      end

      scheduler.at_interval :droplet_gc do
        gc_droplets
      end

      scheduler.at_interval :check_nats_availability do
        actual_state.check_availability
      end

      if should_shadow?
        scheduler.at_interval :check_shadowing do
          shadower.check_shadowing
        end
      end
    end

    # Currently we do not check that desired state
    # is available; therefore, HM can be overly aggressive stopping apps.
    def on_extra_app(app_state)
      return unless desired_state.available?
      instance_ids_with_reasons = app_state.all_instances.map { |i| [i["instance"], "Extra app"] }
      nudger.stop_instances_immediately(app_state, instance_ids_with_reasons)
    end

    # ------------------------------------------------------------
    # Flapping-related code STARTS

    # TODO: consider refactoring. There are some unpleasant
    # abstraction leaks, e.g. calculations involving number of
    # crashes, predicate methods, etc.  Consider making "instance"
    # into a full-fledged object

    def execute_flapping_policy(app_state, index, instance, chatty)
      unless app_state.restart_pending?(index)
        instance['last_action'] = now
        if giveup_restarting?(instance)
          logger.info { "given up on restarting: app_id=#{app_state.id} index=#{index}" } if chatty
        else
          delay = calculate_delay(instance)
          schedule_delayed_restart(app_state, instance, index, delay)
        end
      end
    end

    def flapping?(instance)
      instance['state'] == FLAPPING
    end

    def giveup_restarting?(instance)
      interval(:giveup_crash_number) > 0 && instance['crashes'] > interval(:giveup_crash_number)
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
               interval(:min_restart_delay) << (instance['crashes'] - interval(:flapping_death) - 1)
              ].min.to_f
      noise_amount = 2.0 * (rand - 0.5) * interval(:delay_time_noise).to_f

      result = delay + noise_amount

      logger.info("delay: #{delay} noise: #{noise_amount} result: #{result}")
      result
    end

    def schedule_delayed_restart(app_state, instance, index, delay)
      receipt = scheduler.after(delay) do
        app_state.remove_pending_restart(index)
        instance['last_action'] = now
        nudger.start_flapping_instance_immediately(app_state, index)
      end
      app_state.add_pending_restart(index, receipt)
    end

    def abort_all_pending_delayed_restarts(app_state)
      app_state.pending_restarts.each do |_, receipt|
        scheduler.cancel(receipt)
      end
      app_state.pending_restarts.clear
    end

    # Flapping-related code ENDS
    # ------------------------------------------------------------

    def gc_droplets
      before = @droplet_registry.size
      @droplet_registry.delete_if { |_,d| d.ripe_for_gc? }
      after = @droplet_registry.size
      logger.info("harmonizer: droplet GC ran. Number of droplets before: #{before}, after: #{after}. #{before-after} droplets removed")
    end

    def analyze_all_apps
      if scheduler.task_running? :droplets_analysis
        logger.warn("Droplet analysis still in progress.  Consider increasing droplets_analysis interval.")
        return
      end

      return unless desired_state.available?

      start_at = Time.now
      logger.debug { "harmonizer: droplets_analysis" }

      varz.reset_realtime!
      scheduler.start_task :droplets_analysis do
        @droplet_registry.each do |_, droplet|
          if droplet
            droplet.analyze
            droplet.update_realtime_varz(varz)
            true
          else # no more droplets to iterate through, finish up
            if @droplet_registry.size <= interval(:max_droplets_in_varz)
              varz[:droplets] = @droplet_registry
            else
              varz[:droplets] = {}
            end
            varz.publish

            elapsed = Time.now - start_at
            varz[:analysis_loop_duration] = elapsed

            logger.info ["harmonizer: Analyzed #{varz[:running_instances]} running ",
              "#{varz[:missing_instances]} missing instances. ",
              "Elapsed time: #{elapsed}"
            ].join
            false #signal :droplets_analysis task completion to the scheduler
          end
        end
      end
    end

    def update_desired_state
      desired_state.update_user_counts
      varz.reset_desired!
      desired_state.each_droplet do |droplet_id, desired_droplet|
        @droplet_registry.get(droplet_id).set_desired_state(desired_droplet)
      end
    end

    def postpone_desired_state_update
      if @postponed
        logger.info("harmonizer: update_desired_state is currently running, and a postponed one is already scheduled.  Ignoring.")
      else
        logger.info("harmonizer: postponing desired_state_update")
        @postponed = scheduler.after_interval :postpone_update do
          logger.info("harmonizer: starting postponed desired_state_update")
          @postponed = nil
          update_desired_state
        end
      end
    end
  end
end

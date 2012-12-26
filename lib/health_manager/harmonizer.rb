# This class describes in a declarative manner the policy that
# HealthManager is implementing.  It describes a set of rules that
# recognize certain conditions (e.g. missing instances, etc) and
# initiates certain actions (e.g. restarting the missing instances)

module HealthManager
  class Harmonizer
    include HealthManager::Common

    def initialize(config = {})
      @config = config
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
      AppState.flapping_timeout = interval(:flapping_timeout)
      AppState.flapping_death = interval(:flapping_death)
      AppState.droplet_gc_grace_period = interval(:droplet_gc_grace_period)

      #set up listeners for anomalous events to respond with correcting actions
      AppState.add_listener(:missing_instances) do |app_state, missing_indices|
        if app_state.stale?
          logger.info { "harmonizer: stale: missing_instances ignored app_id=#{app_state.id} indices=#{missing_indices}" }
          next
        end

        logger.debug { "harmonizer: missing_instances"}
        missing_indices.each do |index|
          instance = app_state.get_instance(index)
          if flapping?(instance)
            execute_flapping_policy(app_state, index, instance)
          else
            nudger.start_instance(app_state, index, NORMAL_PRIORITY)
          end
        end
      end

      AppState.add_listener(:extra_instances) do |app_state, extra_instances|
        if app_state.stale?
          logger.info { "harmonizer: stale: extra_instances ignored: #{extra_instances}" }
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
          execute_flapping_policy(app_state, index, instance)
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
        app_state.mark_stale
        abort_all_pending_delayed_restarts(app_state)
        update_expected_state
      end

      #schedule time-based actions

      scheduler.immediately { update_expected_state }

      scheduler.at_interval :request_queue do
        nudger.deque_batch_of_requests
      end

      scheduler.at_interval :expected_state_update do
        update_expected_state
      end

      scheduler.after_interval :droplet_lost do
        scheduler.at_interval :droplets_analysis do
          analyze_all_apps
        end
      end

      scheduler.at_interval :droplet_gc do
        gc_droplets
      end

      if should_shadow?
        scheduler.at_interval :check_shadowing do
          shadower.check_shadowing
        end
      end
    end

    # ------------------------------------------------------------
    # Flapping-related code STARTS

    # TODO: consider refactoring. There are some unpleasant
    # abstraction leaks, e.g. calculations involving number of
    # crashes, predicate methods, etc.  Consider making "instance"
    # into a full-fledged object

    def execute_flapping_policy(app_state, index, instance)
      unless app_state.restart_pending?(index)
        instance['last_action'] = now
        if giveup_restarting?(instance)
          logger.info { "given up on restarting: app_id=#{app_state.id} index=#{index}" }
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
      before = known_state_provider.droplets.size
      known_state_provider.droplets.delete_if { |_,d| d.ripe_for_gc? }
      after = known_state_provider.droplets.size
      logger.info("harmonizer: droplet GC ran. Number of droplets before: #{before}, after: #{after}. #{before-after} droplets removed")
    end

    def analyze_all_apps
      if scheduler.task_running? :droplets_analysis
        logger.warn("Droplet analysis still in progress.  Consider increasing droplets_analysis interval.")
        return
      end

      start_at = Time.now
      logger.debug { "harmonizer: droplets_analysis" }

      varz.reset_realtime_stats
      known_state_provider.rewind

      scheduler.start_task :droplets_analysis do
        known_droplet = known_state_provider.next_droplet
        if known_droplet
          known_droplet.analyze
          varz.update_realtime_stats_for_droplet(known_droplet)
          true
        else # no more droplets to iterate through, finish up
          if known_state_provider.droplets.size <= interval(:max_droplets_in_varz)
            varz.set(:droplets, known_state_provider.droplets)
          else
            varz.set(:droplets, {})
          end
          varz.publish_realtime_stats

          elapsed = Time.now - start_at
          varz.set(:analysis_loop_duration, elapsed)

          logger.info ["harmonizer: Analyzed #{varz.get(:running_instances)} running ",
                       "#{varz.get(:missing_instances)} missing instances. ",
                       "Elapsed time: #{elapsed}"
                      ].join
          false #signal :droplets_analysis task completion to the scheduler
        end
      end
    end

    def update_expected_state
      logger.debug { "harmonizer: expected_state_update pre-check" }

      if expected_state_update_in_progress?
        postpone_expected_state_update
        return
      end

      start_at = Time.now

      expected_state_provider.update_user_counts
      varz.reset_expected_stats
      expected_state_provider.each_droplet do |app_id, expected|
        known = known_state_provider.get_droplet(app_id)
        expected_state_provider.set_expected_state(known, expected)
      end

      elapsed = Time.now - start_at
      varz.set(:bulk_update_loop_duration, elapsed)
      logger.info { "harmonizer: Expected State Update complete. Elapsed time: #{elapsed}" }
    end

    def postpone_expected_state_update
      if @postponed
        logger.info("harmonizer: update_expected_state is currently running, and a postponed one is already scheduled.  Ignoring.")
      else
        logger.info("harmonizer: postponing expected_state_update")
        @postponed = scheduler.after_interval :postpone_update do
          logger.info("harmonizer: starting postponed expected_state_update")
          @postponed = nil
          update_expected_state
        end
      end
    end

    def expected_state_update_in_progress?
      varz.held?(:total)
    end
  end
end

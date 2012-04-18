# This class describes in a declarative manner the policy that HealthManager is implementing.
# It describes a set of rules that recognize certain conditions (e.g. missing instances, etc) and
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


      #set up listeners for anomalous events to respond with correcting actions
      AppState.add_listener(:missing_instances) do |app_state|
        logger.info { "harmonizer: missing_instances"}
        nudger.start_missing_instances(app_state,NORMAL_PRIORITY)
      end

      AppState.add_listener(:extra_instances) do |app_state, extra_instances|
        logger.info { "harmonizer: extra_instances"}
        nudger.stop_instances_immediately(app_state, extra_instances)
      end

      AppState.add_listener(:exit_dea) do |app_state, message|
        index = message['index']

        logger.info { "harmonizer: exit_dea: app_id=#{app_state.id} index=#{index}" }
        nudger.start_instance(app_state, index, HIGH_PRIORITY)
      end

      AppState.add_listener(:exit_crashed) do |app_state, message|

        index = message['index']
        logger.info { "harmonizer: exit_crashed" }

        if flapping?(app_state, message['version'], message['index'])
          # TODO: implement delayed restarts
        else
          nudger.start_instance(app_state,index,LOW_PRIORITY)
          # app_state.reset_missing_indices
        end
      end

      AppState.add_listener(:droplet_updated) do |*args|
        logger.info { "harmonizer: droplet_updated" }
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
        scheduler.at_interval :droplet_analysis do
          analyze_all_apps
        end
      end
    end

    def flapping?(droplet, version, index)
      instance = droplet.get_instance(version, index)
      if instance['crashes'] > interval(:flapping_death)
        instance['state'] = FLAPPING
      end
      instance['state'] == FLAPPING
    end

    def analyze_all_apps
      if scheduler.task_running? :droplet_analysis
        logger.warn("Droplet analysis still in progress.  Consider increasing droplet_analysis interval.")
        return
      end

      logger.debug { "harmonizer: droplet_analysis" }

      varz.reset_realtime_stats
      known_state_provider.rewind

      scheduler.start_task :droplet_analysis do
        known_droplet = known_state_provider.next_droplet
        if known_droplet
          known_droplet.analyze
          varz.update_realtime_stats_for_droplet(known_droplet)
          true
        else
          # TODO: remove
          varz.set(:droplets, known_state_provider.droplets)
          varz.publish_realtime_stats

          # TODO: add elapsed time
          logger.info ["harmonizer: Analyzed #{varz.get(:running_instances)} running ",
                       "#{varz.get(:down_instances)} down instances"].join
          false #signal :droplet_analysis task completion to the scheduler
        end
      end
    end

    def update_expected_state
      logger.debug { "harmonizer: expected_state_update pre-check" }

      if expected_state_update_in_progress?
        postpone_expected_state_update
        return
      end

      varz.reset_expected_stats
      expected_state_provider.each_droplet do |app_id, expected|
        known = known_state_provider.get_droplet(app_id)
        expected_state_provider.set_expected_state(known, expected)
      end
    end

    def postpone_expected_state_update
      if @postponed
        logger.info("harmonizer: update_expected_state is currently running, and a postponed one is already scheduled.  Ignoring.")
      else
        logger.info("harmonizer: postponing expected_state_update")
        @postponed = scheduler.after_interval :postpone do
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

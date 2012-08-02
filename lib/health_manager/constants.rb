require 'set'

module HealthManager

  COMPONENTS = [:manager,
                :harmonizer,
                :known_state_provider,
                :expected_state_provider,
                :scheduler,
                :nudger,
                :varz,
                :reporter,
                :publisher,
                :shadower
               ]

  #restart priorities
  LOW_PRIORITY           = 1
  NORMAL_PRIORITY        = 1000
  HIGH_PRIORITY          = 1_000_000

  DEFAULTS = {


    #intervals
    :expected_state_update    => 10,
    :analysis_delay           => 5,
    :droplets_analysis         => 20,
    :droplet_lost             => 30,
    :postpone_update          => 2,
    :request_queue            => 1,
    :queue_batch_size         => 40,
    :nats_request_timeout     => 5,
    :run_loop_interval        => 2,
    :flapping_timeout         => 500,
    :flapping_death           => 1,
    :giveup_crash_number      => 4,
    :min_restart_delay        => 60,
    :max_restart_delay        => 480,
    :max_shadowing_delay      => 10,
    :check_shadowing          => 30,
    :delay_time_noise         => 5,

  }

  #package states
  STAGED            = 'STAGED'
  PENDING           = 'PENDING'
  FAILED            = 'FAILED'

  #app states
  DOWN              = 'DOWN'
  STARTED           = 'STARTED'
  STOPPED           = 'STOPPED'
  CRASHED           = 'CRASHED'
  STARTING          = 'STARTING'
  RUNNING           = 'RUNNING'
  FLAPPING          = 'FLAPPING'
  DEA_SHUTDOWN      = 'DEA_SHUTDOWN'
  DEA_EVACUATION    = 'DEA_EVACUATION'
  APP_STABLE_STATES = Set.new([STARTED, STOPPED])
  RUNNING_STATES    = Set.new([STARTING, RUNNING])
  RESTART_REASONS   = Set.new([CRASHED, DEA_SHUTDOWN, DEA_EVACUATION])

  #environment options
  NATS_URI          = 'NATS_URI'
  LOG_LEVEL         = 'LOG_LEVEL'
  HM_SHADOW         = 'HM_SHADOW'
end

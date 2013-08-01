require 'set'

module HealthManager

  #restart priorities
  LOW_PRIORITY           = 1
  NORMAL_PRIORITY        = 1000
  HIGH_PRIORITY          = 1_000_000

  MAX_BULK_ERROR_COUNT   = 10

  DEFAULTS = {
    :cc_partition => "default",
    :number_of_droplets_analyzed_per_analysis_iteration => 200,
    :intervals => {
      :desired_state_update    => 60,
      :analysis_delay           => 5,
      :droplets_analysis         => 20,
      :droplet_lost             => 30,
      :desired_state_lost      => 180,
      :postpone_update          => 30,
      :request_queue            => 1,
      :queue_batch_size         => 40,
      :bulk_credentials_timeout => 5,
      :run_loop_interval        => 2,
      :flapping_timeout         => 500,
      :flapping_death           => 1,
      :giveup_crash_number      => 4,
      :min_restart_delay        => 60,
      :max_restart_delay        => 480,
      :delay_time_noise         => 5,
      :droplet_gc_grace_period  => 240,
      :droplet_gc               => 300,
    }
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
  MBUS_URI          = 'MBUS_URI'
  LOG_LEVEL         = 'LOG_LEVEL'
end

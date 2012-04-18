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
               ]

  #restart priorities
  LOW_PRIORITY           = 1
  NORMAL_PRIORITY        = 1000
  HIGH_PRIORITY          = 1_000_000

  MAX_HEARTBEATS_SAVED   = 5
  QUEUE_BATCH_SIZE       = 40

  #intervals
  EXPECTED_STATE_UPDATE  = 10
  ANALYSIS_DELAY         = 5
  DROPLET_ANALYSIS       = 10
  DROPLET_LOST           = 30
  POSTPONE               = 2
  REQUEST_QUEUE          = 1
  NATS_REQUEST_TIMEOUT   = 5
  RUN_LOOP_INTERVAL      = 2
  FLAPPING_TIMEOUT       = 60
  FLAPPING_DEATH         = 1


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

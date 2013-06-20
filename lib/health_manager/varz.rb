module HealthManager
  DEFAULT_DESIRED = {
    :users => [],
    :apps => [],
    :total => {
      :apps => 0,
      :started_apps => 0,
      :instances => 0,
      :started_instances => 0,
      :memory => 0,
      :started_memory => 0
    }.freeze
  }.freeze

  DEFAULT_REALTIME = {
    :total_apps => 0,
    :total_instances => 0,
    :running_instances => 0,
    :missing_instances => 0,
    :crashed_instances => 0,
    :flapping_instances => 0,
    :running => {
      :apps => 0,
      :crashes => 0,
      :running_instances => 0,
      :missing_instances => 0,
      :flapping_instances => 0
    }.freeze
  }.freeze

  class Varz < Hash
    include HealthManager::Common

    def initialize(config={})
      @config = config
      @desired_stats_reset_at = Time.now
      self.merge!({
        :total_users => 0,
        :queue_length => 0,
        :heartbeat_msgs_received => 0,
        :droplet_exited_msgs_received => 0,
        :droplet_updated_msgs_received => 0,
        :healthmanager_status_msgs_received => 0,
        :healthmanager_health_request_msgs_received => 0,
        :healthmanager_droplet_request_msgs_received => 0,
        :analysis_loop_duration => 0,
        :bulk_update_loop_duration => 0,
        :varz_publishes => 0,
        :varz_holds => 0,
        :droplets => {}, # FIXIT: remove
        :state => "RUNNING",
        :last_up_known => nil
      }.merge(deep_dup(DEFAULT_DESIRED)).merge(deep_dup(DEFAULT_REALTIME)))
    end

    def reset_desired!
      @desired_stats_reset_at = Time.now
      self.merge!(deep_dup(DEFAULT_DESIRED))
    end

    def reset_realtime!
      self.merge!(deep_dup(DEFAULT_REALTIME))
    end

    def publish_desired_stats
      self[:bulk_update_loop_duration] = Time.now - @desired_stats_reset_at
      publish
    end

    def publish
      deep_merge!(VCAP::Component.varz, deep_dup(self))
    end

    private

    def deep_dup(hash)
      result = hash.dup
      result.each do |key, value|
        result[key] = deep_dup(value) if value.is_a?(Hash)
      end
      result
    end

    def deep_merge(first_hash, other_hash)
      first_hash.merge(other_hash) do |_, oldval, newval|
        oldval = oldval.to_hash if oldval.respond_to?(:to_hash)
        newval = newval.to_hash if newval.respond_to?(:to_hash)
        oldval.class.to_s == 'Hash' && newval.class.to_s == 'Hash' ? deep_merge(oldval, newval) : newval
      end
    end

    def deep_merge!(first_hash, other_hash)
      first_hash.replace(deep_merge(first_hash, other_hash))
    end
  end
end

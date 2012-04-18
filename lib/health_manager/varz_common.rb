# This is a wrapper/helper over VCAP::Component varz/ functionality.
# perhaps a part of this should be lifted to common/component.

module HealthManager
  class Varz
    def initialize(config = {})
      @config = config
      @counters = {}
      @holds = {}
    end

    def real_varz
      VCAP::Component.varz || {}
    end

    def hold(*path)
      check_var_exists(*path)
      @holds[path] = true
    end

    def held?(*path)
      partial = []
      path.any? { |leg| partial << leg; @holds[partial] }
    end

    def sync(*path)
      return if held?(*path)
      h, k = get_last_hash_and_key!(real_varz, *path)
      h[k] = get(*path)
    end

    def release(*path)
      raise ArgumentError.new("Path #{path} is not held") unless @holds[path]
      @holds.delete(path)
    end

    def publish
      inc(:varz_publishes)
      set(:varz_holds, @holds.size)
      publish_not_held_recursively(real_varz, get_varz)
    end

    def publish_not_held_recursively(lvalue, rvalue, *path)
      return if held?(*path)
      if rvalue.kind_of?(Hash)
        lvalue = lvalue[path.last] ||= {} unless path.empty?
        rvalue.keys.each { |key|
          publish_not_held_recursively(lvalue, rvalue[key], *path, key)
        }
      else
        lvalue[path.last] = rvalue
      end
    end

    def declare_node(*path)
      check_var_exists(*path[0...-1])
      h,k = get_last_hash_and_key(get_varz, *path)
      h[k] ||= {}
    end

    def declare_collection(*path)
      check_var_exists(*path[0...-1])
      h,k = get_last_hash_and_key(get_varz, *path)
      h[k] ||= []
    end

    def declare_counter(*path)
      check_var_exists(*path[0...-1])

      h,k = get_last_hash_and_key(get_varz, *path)
      raise ArgumentError.new("Counter #{path} already declared") if h[k]
      h[k] = 0
    end

    def reset(*path)
      check_var_exists(*path)
      h,k = get_last_hash_and_key(get_varz, *path)

      if h[k].kind_of? Hash
        h[k].keys.each { |key| reset(*path, key) }
      elsif h[k].kind_of? Integer
        h[k] = 0
      elsif h[k].kind_of? Array
        h[k] = []
      else
        raise ArgumentError.new("Don't know how to reset varz at path #{path}: #{h[k]} (#{h[k].class})")
      end
    end

    def push(*path, value)
      check_var_exists(*path)
      h,k= get_last_hash_and_key(get_varz, *path)
      raise ArgumentError.new("Varz #{path} is not an Array, can't push") unless h[k].kind_of?(Array)
      h[k] << value
      sync(*path)
      h[k]
    end

    def add(*path, value)
      check_var_exists(*path)
      h,k= get_last_hash_and_key(get_varz, *path)
      h[k] += value
      sync(*path)
      h[k]
    end

    def inc(*path)
      add(*path, 1)
    end

    def get(*path)
      check_var_exists(*path)
      h,k = get_last_hash_and_key(get_varz, *path)
      h[k]
    end

    def set(*path, value)
      check_var_exists(*path)
      h,k = get_last_hash_and_key(get_varz, *path)
      h[k] = value
    end

    def get_varz
      @counters
    end

    private

    def get_last_hash_and_key!(source, *path)
      counter = source ||= {}
      path[0...-1].each { |p| counter = counter[p] ||= {}}
      return counter, path.last
    end

    def get_last_hash_and_key(source, *path)
      counter = source
      path[0...-1].each { |p| counter = counter[p] }
      return counter, path.last
    end

    def check_var_exists(*path)
      c = @counters
      path.each { |var|
        raise ArgumentError.new("undeclared: #{var} in #{path}") unless c[var]
        c = c[var]
      }
    end
  end
end

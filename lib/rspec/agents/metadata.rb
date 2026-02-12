module RSpec
  module Agents
    # Provides indifferent access to metadata (symbols and strings are equivalent)
    # Supports dynamic attributes, scoped assignment, and deep access
    class Metadata
      def initialize(data = {})
        @data = {}
        data.each { |k, v| @data[k.to_sym] = v }
      end

      def [](key)
        @data[key.to_sym]
      end

      def []=(key, value)
        @data[key.to_sym] = value
      end

      def key?(key)
        @data.key?(key.to_sym)
      end

      def fetch(key, *args, &block)
        @data.fetch(key.to_sym, *args, &block)
      end

      def merge(other)
        self.class.new(@data.merge(normalize_keys(other)))
      end

      def to_h
        deep_to_h(@data)
      end

      def ==(other)
        case other
        when Metadata
          to_h == other.to_h
        when Hash
          to_h == deep_to_h(normalize_keys(other))
        else
          false
        end
      end

      def empty?
        @data.empty?
      end

      # Scoped assignment for grouped data
      # @example Single scope
      #   metadata.scope!(:tracing) { |t| t.latency_ms = 2340 }
      # @example Nested scopes
      #   metadata.scope!(:tracing, :tokens) { |t| t.input = 1523 }
      def scope!(*keys)
        raise ArgumentError, "scope! requires at least one key" if keys.empty?

        current = self
        keys.each do |key|
          key = key.to_sym
          current[key] ||= Metadata.new
          current = current[key]
        end
        yield current if block_given?
        current
      end

      # Deep access for nested data
      # @example
      #   metadata.dig(:tracing, :tokens, :input)
      def dig(*keys)
        return nil if keys.empty?

        value = @data[keys.first.to_sym]
        return nil if value.nil?
        return value if keys.length == 1

        if value.respond_to?(:dig)
          value.dig(*keys[1..])
        else
          nil
        end
      end

      # Dynamic attribute access
      def method_missing(method_name, *args, &block)
        method_str = method_name.to_s
        if method_str.end_with?("=")
          # Setter: metadata.foo = value
          key = method_str.chomp("=").to_sym
          self[key] = args.first
        else
          # Getter: metadata.foo
          self[method_name]
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        true
      end

      private

      def normalize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      def deep_to_h(obj)
        case obj
        when Metadata
          obj.to_h
        when Hash
          obj.transform_values { |v| deep_to_h(v) }
        else
          obj
        end
      end
    end
  end
end

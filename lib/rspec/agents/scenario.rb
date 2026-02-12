require "digest"
require "json"

module RSpec
  module Agents
    # Immutable wrapper for scenario data
    # Provides stable identifiers and hash-like access to scenario attributes
    #
    # Scenarios are data-driven test instances that parameterize the user simulator
    # while maintaining a stable topic graph structure.
    #
    # @example Basic usage
    #   scenario = Scenario.new(
    #     id: "corporate_workshop",
    #     name: "Corporate workshop in Stuttgart",
    #     goal: "Find a venue for 50 people",
    #     context: ["Works at Acme GmbH"],
    #     personality: "Professional"
    #   )
    #   scenario[:goal] # => "Find a venue for 50 people"
    #   scenario.identifier # => "scenario_a1b2c3d4"
    #
    class Scenario
      attr_reader :data, :index

      # @param data [Hash] Scenario attributes
      # @param index [Integer, nil] Optional index in scenario set
      def initialize(data, index: nil)
        @data = data.is_a?(Hash) ? data.transform_keys(&:to_sym) : {}
        @index = index
      end

      # Access scenario data by key
      # @param key [Symbol, String] Attribute name
      # @return [Object, nil] Attribute value
      def [](key)
        @data[key.to_sym]
      end

      # Enable dot notation access to scenario data
      # @param method_name [Symbol] Attribute name
      # @param args [Array] Method arguments (unused)
      # @return [Object, nil] Attribute value
      def method_missing(method_name, *args)
        if @data.key?(method_name.to_sym)
          @data[method_name.to_sym]
        else
          super
        end
      end

      # Check if method corresponds to scenario data key
      # @param method_name [Symbol] Method name
      # @param include_private [Boolean] Include private methods
      # @return [Boolean]
      def respond_to_missing?(method_name, include_private = false)
        @data.key?(method_name.to_sym) || super
      end

      # Generate stable identifier for this scenario
      # Uses SHA256 hash of normalized scenario data
      # @return [String] Identifier in format "scenario_XXXXXXXX"
      def identifier
        @identifier ||= begin
          # Normalize data for consistent hashing
          normalized = normalize_for_hash(@data)
          hash_value = Digest::SHA256.hexdigest(normalized.to_json)
          "scenario_#{hash_value[0..7]}"
        end
      end

      # Convert to hash
      # @return [Hash]
      def to_h
        @data.dup
      end

      # Convert to JSON
      # @param options [Hash] JSON generation options
      # @return [String]
      def to_json(*options)
        @data.to_json(*options)
      end

      # Human-readable representation
      # @return [String]
      def inspect
        name = @data[:name] || @data[:id] || "unnamed"
        "#<Scenario:#{identifier} \"#{name}\">"
      end

      # String representation
      # @return [String]
      def to_s
        inspect
      end

      # Equality comparison
      # @param other [Scenario]
      # @return [Boolean]
      def ==(other)
        other.is_a?(Scenario) && other.data == @data
      end

      alias_method :eql?, :==

      # Hash code for use in hashes and sets
      # @return [Integer]
      def hash
        @data.hash
      end

      private

      # Normalize data structure for consistent hashing
      # Sorts hash keys recursively to ensure same data produces same hash
      # @param obj [Object] Data to normalize
      # @return [Object] Normalized data
      def normalize_for_hash(obj)
        case obj
        when Hash
          obj.keys.sort.each_with_object({}) do |key, result|
            result[key.to_s] = normalize_for_hash(obj[key])
          end
        when Array
          obj.map { |item| normalize_for_hash(item) }
        else
          obj
        end
      end
    end
  end
end

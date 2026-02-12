require "digest"

module RSpec
  module Agents
    # Generates stable, content-addressable example identifiers
    #
    # Stable IDs enable cross-experiment comparison by surviving code reorganization,
    # line number changes, and example reordering. The ID is derived from the hierarchy
    # of describe/context/it descriptions, not file positions.
    #
    # @example Basic usage
    #   id = StableExampleId.generate(rspec_example)
    #   id.to_s         # => "example:a1b2c3d4e5f6"
    #   id.canonical_path # => "BookingAgent::venue search::returns results"
    #
    # @example With scenario
    #   id = StableExampleId.generate(rspec_example, scenario: scenario)
    #   id.to_s         # => "example:b2c3d4e5f6a7"
    #   id.canonical_path # => "BookingAgent::handles event@scenario_c3d4e5f6"
    #
    # @see doc/2026_01_30_stable_example_ids-design.md
    class StableExampleId
      SEPARATOR = "::"
      SCENARIO_MARKER = "@"
      PREFIX = "example:"
      HASH_LENGTH = 12

      # Generate stable ID for an RSpec example
      # @param example [RSpec::Core::Example] The RSpec example
      # @param scenario [Scenario, nil] Optional scenario for scenario-driven tests
      # @return [StableExampleId] Stable example ID instance
      def self.generate(example, scenario: nil)
        new(example, scenario: scenario)
      end

      # @param example [RSpec::Core::Example] The RSpec example
      # @param scenario [Scenario, nil] Optional scenario for scenario-driven tests
      def initialize(example, scenario: nil)
        @example = example
        @scenario = scenario
      end

      # The full stable ID
      # @return [String] Format: "example:<12-char-hash>"
      def to_s
        @id ||= "#{PREFIX}#{hash_value}"
      end

      # The canonical path before hashing (useful for debugging)
      # @return [String] Human-readable path
      def canonical_path
        @canonical_path ||= build_canonical_path
      end

      # Just the hash portion
      # @return [String] 12-character hex hash
      def hash_value
        @hash_value ||= Digest::SHA256.hexdigest(canonical_path)[0, HASH_LENGTH]
      end

      # Equality based on the stable ID string
      # @param other [StableExampleId, String]
      # @return [Boolean]
      def ==(other)
        case other
        when StableExampleId
          to_s == other.to_s
        when String
          to_s == other
        else
          false
        end
      end

      alias_method :eql?, :==

      # Hash code for use in hashes and sets
      # @return [Integer]
      def hash
        to_s.hash
      end

      # Inspect representation
      # @return [String]
      def inspect
        "#<StableExampleId #{self} path=#{canonical_path.inspect}>"
      end

      private

      def build_canonical_path
        path = descriptions.map { |d| normalize(d) }.join(SEPARATOR)

        scenario_component = build_scenario_component
        if scenario_component
          path = "#{path}#{SCENARIO_MARKER}#{scenario_component}"
        end

        path
      end

      def descriptions
        # Collect from outermost describe to innermost it
        # parent_groups returns [immediate_parent, grandparent, ...] so we reverse
        groups = @example.example_group.parent_groups.reverse
        group_descriptions = groups.map(&:description)
        group_descriptions + [@example.description]
      end

      def build_scenario_component
        return nil unless @scenario

        case @scenario
        when Scenario
          @scenario.identifier
        when Hash
          # Fallback for raw hash scenarios
          normalized = normalize_hash_for_id(@scenario)
          hash = Digest::SHA256.hexdigest(normalized.to_json)[0, 8]
          "data_#{hash}"
        else
          nil
        end
      end

      def normalize(text)
        normalized = text.to_s
        normalized = normalized.unicode_normalize(:nfc) if normalized.respond_to?(:unicode_normalize)
        normalized = normalized.gsub(/\s+/, " ").strip
        normalized.empty? ? "(anonymous)" : normalized
      end

      def normalize_hash_for_id(hash)
        case hash
        when Hash
          hash.keys.sort.each_with_object({}) do |key, result|
            result[key.to_s] = normalize_hash_for_id(hash[key])
          end
        when Array
          hash.map { |item| normalize_hash_for_id(item) }
        else
          hash
        end
      end
    end
  end
end

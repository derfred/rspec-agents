require "json"
require_relative "scenario"

module RSpec
  module Agents
    # Loads scenarios from external data sources
    # Currently supports JSON files with plans for YAML and programmatic generation
    #
    # @example Loading from JSON file
    #   scenarios = ScenarioLoader.load("scenarios/venues.json")
    #   scenarios.each do |scenario|
    #     puts scenario[:name]
    #   end
    #
    class ScenarioLoader
      class LoadError < StandardError; end
      class ValidationError < StandardError; end

      # Load scenarios from a data source
      # @param source [String] File path to JSON file
      # @param base_path [String, nil] Base directory for resolving relative paths
      # @return [Array<Scenario>] Array of loaded scenarios
      # @raise [LoadError] If file cannot be loaded
      # @raise [ValidationError] If scenario data is invalid
      def self.load(source, base_path: nil)
        if source.is_a?(String) && (source.end_with?(".json") || source.end_with?(".JSON"))
          load_json(source, base_path: base_path)
        else
          raise LoadError, "Unsupported scenario source: #{source}. Only .json files are currently supported."
        end
      end

      # Load scenarios from an inline array of hashes
      # @param scenarios_array [Array<Hash>] Array of scenario data hashes
      # @return [Array<Scenario>] Array of loaded scenarios
      # @raise [ValidationError] If scenario data is invalid
      def self.load_from_array(scenarios_array)
        parse_scenarios(scenarios_array, "inline array")
      end

      # Load scenarios from JSON file
      # @param file_path [String] Path to JSON file
      # @param base_path [String, nil] Base directory for resolving relative paths
      # @return [Array<Scenario>] Array of loaded scenarios
      # @raise [LoadError] If file cannot be loaded
      # @raise [ValidationError] If JSON structure is invalid
      def self.load_json(file_path, base_path: nil)
        resolved_path = resolve_path(file_path, base_path)

        unless File.exist?(resolved_path)
          raise LoadError, "Scenario file not found: #{resolved_path}"
        end

        begin
          content = File.read(resolved_path, encoding: "UTF-8")
          data = JSON.parse(content)
        rescue JSON::ParserError => e
          raise LoadError, "Invalid JSON in scenario file #{resolved_path}: #{e.message}"
        rescue Errno::EACCES => e
          raise LoadError, "Permission denied reading scenario file #{resolved_path}: #{e.message}"
        rescue StandardError => e
          raise LoadError, "Error reading scenario file #{resolved_path}: #{e.message}"
        end

        parse_scenarios(data, resolved_path)
      end

      # Parse scenario data and wrap in Scenario objects
      # @param data [Object] Parsed JSON data
      # @param file_path [String] Original file path (for error messages)
      # @return [Array<Scenario>] Array of scenarios
      # @raise [ValidationError] If data structure is invalid
      def self.parse_scenarios(data, file_path)
        unless data.is_a?(Array)
          raise ValidationError, "Scenario file #{file_path} must contain a JSON array, got #{data.class}"
        end

        data.each_with_index.map do |scenario_data, index|
          validate_scenario(scenario_data, index, file_path)
          Scenario.new(scenario_data, index: index)
        end
      end

      # Validate scenario data structure
      # @param data [Object] Scenario data
      # @param index [Integer] Scenario index in array
      # @param file_path [String] Original file path (for error messages)
      # @raise [ValidationError] If scenario is invalid
      def self.validate_scenario(data, index, file_path)
        unless data.is_a?(Hash)
          raise ValidationError, "Scenario at index #{index} in #{file_path} must be a hash, got #{data.class}"
        end

        # Validate required fields
        required_fields = [:name, :goal]
        missing_fields = required_fields.reject { |field| data.key?(field.to_s) || data.key?(field) }

        unless missing_fields.empty?
          raise ValidationError, "Scenario at index #{index} in #{file_path} is missing required fields: #{missing_fields.join(', ')}"
        end

        # Validate field types if present
        validate_field_type(data, :name, String, index, file_path)
        validate_field_type(data, :goal, String, index, file_path)
        validate_field_type(data, :context, Array, index, file_path, optional: true)
        validate_field_type(data, :personality, String, index, file_path, optional: true)
        validate_field_type(data, :verification, Hash, index, file_path, optional: true)
      end

      # Validate that a field has the expected type
      # @param data [Hash] Scenario data
      # @param field [Symbol] Field name
      # @param expected_type [Class] Expected type
      # @param index [Integer] Scenario index
      # @param file_path [String] Original file path
      # @param optional [Boolean] Whether field is optional
      # @raise [ValidationError] If field has wrong type
      def self.validate_field_type(data, field, expected_type, index, file_path, optional: false)
        value = data[field.to_s] || data[field]
        return if value.nil? && optional
        return if value.nil? && !optional # Will be caught by required field check

        unless value.is_a?(expected_type)
          raise ValidationError, "Scenario at index #{index} in #{file_path}: field '#{field}' must be #{expected_type}, got #{value.class}"
        end
      end

      # Resolve file path relative to base path or absolute
      # @param file_path [String] File path (relative or absolute)
      # @param base_path [String, nil] Base directory for relative paths
      # @return [String] Resolved absolute path
      def self.resolve_path(file_path, base_path)
        return File.expand_path(file_path) if File.absolute_path?(file_path)

        if base_path
          File.expand_path(file_path, base_path)
        else
          File.expand_path(file_path)
        end
      end

      private_class_method :parse_scenarios, :validate_scenario, :validate_field_type, :resolve_path
    end
  end
end

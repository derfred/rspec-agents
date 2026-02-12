# frozen_string_literal: true

require "rspec/core"
require "stringio"
require_relative "../../../rspec/agents"

module RSpec
  module Agents
    module Parallel
      # Reference to an individual RSpec example
      ExampleRef = Data.define(:id, :location, :full_description)

      # Discovers RSpec examples using in-process APIs without executing them
      class ExampleDiscovery
        class DiscoveryError < StandardError; end

        def self.discover(paths)
          new.discover(paths)
        end

        # Enumerate all examples from the given spec paths
        #
        # @param paths [Array<String>] Spec files or directories (supports line filters like "spec/foo_spec.rb:42")
        # @return [Array<ExampleRef>] Discovered examples
        # @raise [DiscoveryError] If example discovery fails
        def discover(paths)
          return [] if paths.empty?

          begin
            # Configure RSpec for discovery (loads helpers first)
            configure_for_discovery(paths)

            # Reset RSpec state for clean discovery (but preserve loaded helpers)
            RSpec.reset
            RSpec.configuration.reset

            # Re-register DSL after reset (reset wipes out config.include calls)
            RSpec::Agents.setup_rspec!

            # Use ConfigurationOptions to parse paths - this handles line number filters (spec/foo.rb:42)
            # and other RSpec CLI features properly
            options = RSpec::Core::ConfigurationOptions.new(paths)
            options.configure(RSpec.configuration)

            # Enable focus filtering (fit/fdescribe/fcontext)
            # This must be set after RSpec.reset since reset clears all configuration
            RSpec.configuration.filter_run_when_matching :focus

            null_output = StringIO.new
            error_output = StringIO.new
            RSpec.configuration.output_stream = null_output
            RSpec.configuration.error_stream = error_output
            RSpec.configuration.formatters.clear

            # Load spec files (defines example groups, but doesn't run them)
            RSpec.configuration.load_spec_files

            # Check if any errors occurred during loading
            error_content = error_output.string
            unless error_content.empty?
              # RSpec writes detailed error messages to error_stream
              raise DiscoveryError, "Errors during spec file loading:\n#{error_content}"
            end

            # Check if RSpec recorded any non-example exceptions (e.g., syntax errors)
            # RSpec tracks these internally but doesn't always write to error_stream
            reporter = RSpec.configuration.reporter
            exception_count = reporter.instance_variable_get(:@non_example_exception_count) || 0
            if exception_count > 0
              raise DiscoveryError, "Failed to load spec files: #{exception_count} error(s) occurred during loading. "\
                                    "This usually indicates syntax errors or missing dependencies. "\
                                    "Try running the specs directly with 'bundle exec rspec #{paths.join(' ')}' to see detailed error messages."
            end

            # Extract example metadata directly from RSpec's world
            extract_examples(RSpec.world.all_examples)
          rescue SyntaxError => e
            # Include file path and line number from backtrace for easier debugging
            location = extract_error_location(e)
            raise DiscoveryError, "Syntax error in spec file#{location}: #{e.message}"
          rescue LoadError => e
            # Show which file failed to load
            raise DiscoveryError, "Failed to load dependencies: #{e.message}\n#{e.backtrace.first}"
          rescue DiscoveryError
            # Re-raise our own errors as-is
            raise
          rescue StandardError => e
            # Provide full context for unexpected errors
            location = extract_error_location(e)
            raise DiscoveryError, "Failed to discover examples#{location}: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
          ensure
            # Clean up - reset state after discovery to avoid pollution
            RSpec.reset
            RSpec.configuration.reset
          end
        end

        private

        # Configure RSpec for example discovery (pre-reset phase)
        # This loads helper files before RSpec.reset wipes out state
        def configure_for_discovery(paths)
          # Add spec directory to load path so helper files can be required
          spec_dir = File.expand_path("spec")
          $LOAD_PATH.unshift(spec_dir) unless $LOAD_PATH.include?(spec_dir)

          # Try to load common helper files that specs may require
          # This allows specs to use `require "agents_helper"` etc.
          %w[spec_helper agents_helper].each do |helper|
            begin
              require helper
            rescue LoadError
              # Helper not found or not needed, continue
            end
          end
        end

        # Extract example metadata from RSpec examples
        #
        # @param examples [Array<RSpec::Core::Example>] RSpec example objects
        # @return [Array<ExampleRef>] Discovered examples
        def extract_examples(examples)
          examples.map do |example|
            ExampleRef.new(
              id:               example.id,
              location:         example.location,
              full_description: example.full_description
            )
          end
        end

        # Extract file and line information from error backtrace
        #
        # @param error [Exception] The error to extract location from
        # @return [String] Formatted location string, or empty if not found
        def extract_error_location(error)
          return "" unless error.backtrace&.first

          # Parse backtrace line: "path/to/file.rb:123:in `method_name'"
          if error.backtrace.first =~ /^(.+):(\d+)/
            file = $1
            line = $2
            # Make path relative to current directory if possible
            relative_path = file.start_with?(Dir.pwd) ? file.sub("#{Dir.pwd}/", "") : file
            " at #{relative_path}:#{line}"
          else
            ""
          end
        end
      end
    end
  end
end

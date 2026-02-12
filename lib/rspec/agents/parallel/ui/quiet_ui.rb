# frozen_string_literal: true

require_relative "output_adapter"

module RSpec
  module Agents
    module Parallel
      module UI
        # Minimal terminal output with dot progress.
        # For large test suites where real-time output is impractical.
        #
        # Terminal output:
        #   .....F...F..........F....
        #
        class QuietUI < OutputAdapter
          attr_reader :failures

          # Progress characters
          DOT_PASS = "."
          DOT_FAIL = "F"
          DOT_PENDING = "*"
          DOT_ERROR = "E"

          def initialize(output: $stdout, color: true)
            super(output: output, color: color)
            @failures = []
            @worker_count = 0
            @example_count = 0
            @completed_count = 0
            @dot_count = 0
            @run_start_time = nil
          end

          def on_run_started(worker_count:, example_count:)
            @worker_count = worker_count
            @example_count = example_count
            @run_start_time = Time.now

            synchronized do
              @output.puts
              @output.puts "#{colorize("\u26a1", :cyan)} Parallel spec runner (#{worker_count} workers)"
              @output.puts
            end
          end

          def on_run_finished(results:)
            synchronized do
              @output.puts if @dot_count > 0
            end
          end

          def on_example_started(worker:, event:)
            # No output for example start in quiet mode
          end

          def on_example_finished(worker:, event:)
            synchronized do
              char = case event
                     when Events::ExamplePassed
                       @dot_count += 1
                       colorize(DOT_PASS, :green)
                     when Events::ExampleFailed
                       @failures << event
                       @dot_count += 1
                       colorize(DOT_FAIL, :red)
                     when Events::ExamplePending
                       @dot_count += 1
                       colorize(DOT_PENDING, :yellow)
                     else
                       DOT_ERROR
                     end

              @output.print char
              @output.flush

              # Wrap at 50 chars
              if @dot_count % 50 == 0
                @output.puts
              end
            end

            @completed_count += 1
          end

          def on_conversation_event(worker:, event:)
            # No output for conversation events in quiet mode
          end

          def on_group_event(worker:, event:)
            # No output for group events in quiet mode
          end

          def on_progress(completed:, total:, failures:)
            # Progress shown via dots
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module RSpec
  module Agents
    module Parallel
      module UI
        # Interface for parallel runner output adapters.
        # Provides hooks for run lifecycle, example events, and conversation events.
        #
        # Implementations:
        # - InteractiveUI: Full-screen TUI with tabs and progress bar
        # - InterleavedUI: Simple line output with worker prefixes (CI-friendly)
        # - QuietUI: Dot progress with log files
        #
        # @example Custom adapter
        #   class MyAdapter < OutputAdapter
        #     def on_example_started(worker:, event:)
        #       puts "[#{worker}] Starting: #{event.description}"
        #     end
        #   end
        #
        class OutputAdapter
          COLORS = {
            red:     "\e[31m",
            green:   "\e[32m",
            yellow:  "\e[33m",
            blue:    "\e[34m",
            magenta: "\e[35m",
            cyan:    "\e[36m",
            white:   "\e[37m",
            dim:     "\e[2m",
            bold:    "\e[1m",
            inverse: "\e[7m",
            reset:   "\e[0m"
          }.freeze

          # Worker colors for interleaved/interactive modes
          WORKER_COLORS = [:cyan, :yellow, :magenta, :blue, :green, :white].freeze

          # @param output [IO] Output stream (default: $stdout)
          # @param color [Boolean] Enable color output
          def initialize(output: $stdout, color: true)
            @output = output
            @color = color
            @mutex = Mutex.new
          end

          # Called when the parallel run starts
          # @param worker_count [Integer] Number of workers
          # @param example_count [Integer] Total number of examples
          def on_run_started(worker_count:, example_count:); end

          # Called when the parallel run finishes
          # @param results [RunResult] Final run results
          def on_run_finished(results:); end

          # Called when an example starts executing on a worker
          # @param worker [Integer] Worker index (0-based)
          # @param event [Events::ExampleStarted] Start event
          def on_example_started(worker:, event:); end

          # Called when an example finishes (pass/fail/pending)
          # @param worker [Integer] Worker index (0-based)
          # @param event [Events::ExamplePassed, ExampleFailed, ExamplePending] Completion event
          def on_example_finished(worker:, event:); end

          # Called for conversation events during execution
          # @param worker [Integer] Worker index (0-based)
          # @param event [Events::*] Conversation event (UserMessage, AgentResponse, etc.)
          def on_conversation_event(worker:, event:); end

          # Called to update progress display
          # @param completed [Integer] Number of completed examples
          # @param total [Integer] Total number of examples
          # @param failures [Integer] Number of failed examples
          def on_progress(completed:, total:, failures:); end

          # Called for group events (describe/context blocks)
          # @param worker [Integer] Worker index (0-based)
          # @param event [Events::GroupStarted, GroupFinished] Group event
          def on_group_event(worker:, event:); end

          # Cleanup resources (called at run end)
          def cleanup; end

          # Start any async input handling (keyboard, etc.)
          def start_input_handling; end

          # Stop async input handling
          def stop_input_handling; end

          # Get failures collected during the run
          # @return [Array<Events::ExampleFailed>]
          def failures
            []
          end

          protected

          def colorize(text, color)
            return text unless @color
            "#{COLORS[color]}#{text}#{COLORS[:reset]}"
          end

          def worker_color(worker_index)
            WORKER_COLORS[worker_index % WORKER_COLORS.size]
          end

          def synchronized(&block)
            @mutex.synchronize(&block)
          end

          def format_duration(seconds)
            return "0ms" unless seconds
            seconds < 1 ? "#{(seconds * 1000).round}ms" : "#{seconds.round(2)}s"
          end

          def truncate(text, length)
            return "" unless text
            text = text.to_s.gsub(/\s+/, " ").strip
            text.length > length ? "#{text[0, length - 3]}..." : text
          end
        end
      end
    end
  end
end

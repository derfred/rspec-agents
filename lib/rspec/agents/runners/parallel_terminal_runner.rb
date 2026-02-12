# frozen_string_literal: true

require "async"
require "fileutils"
require_relative "../parallel/ui/ui_factory"

module RSpec
  module Agents
    module Runners
      # CLI-focused parallel runner with formatted terminal output.
      # Thin adapter over SpecExecutor that handles UI display and output serialization.
      #
      # Supports three output modes:
      # - Interactive: Full-screen TUI with tabs and progress bar
      # - Interleaved: Simple streaming output with worker prefixes (CI-friendly)
      # - Quiet: Dot progress with log files
      #
      # @example Basic usage
      #   runner = ParallelTerminalRunner.new(worker_count: 4)
      #   exit_code = runner.run(["spec/"])
      #
      # @example With explicit UI mode
      #   runner = ParallelTerminalRunner.new(worker_count: 4, ui_mode: :interactive)
      #   runner.run(["spec/"])
      #
      class ParallelTerminalRunner
        COLORS = {
          red:    "\e[31m",
          green:  "\e[32m",
          yellow: "\e[33m",
          blue:   "\e[34m",
          cyan:   "\e[36m",
          dim:    "\e[2m",
          white:  "\e[37m",
          reset:  "\e[0m"
        }.freeze

        # @param worker_count [Integer] Number of parallel workers
        # @param fail_fast [Boolean] Stop on first failure
        # @param output [IO] Output stream (default: $stdout)
        # @param color [Boolean, nil] Force color on/off (default: auto-detect)
        # @param json_path [String, nil] Path to save JSON run data
        # @param html_path [String, nil] Path to save HTML report
        # @param ui_mode [Symbol, nil] Output mode (:interactive, :interleaved, :quiet)
        def initialize(worker_count:, fail_fast: false, output: $stdout, color: nil,
                       json_path: nil, html_path: nil, ui_mode: nil)
          @worker_count = worker_count
          @fail_fast = fail_fast
          @output = output
          @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color
          @mutex = Mutex.new
          @json_path = json_path
          @html_path = html_path

          @ui = Parallel::UI::UIFactory.create(
            mode:   ui_mode,
            output: output,
            color:  @color
          )

          # Track which worker is running which example
          @example_to_worker = {} # example_id => worker_index
        end

        # Run specs and return exit code
        # @param paths [Array<String>] Spec files or directories
        # @return [Integer] Exit code (0 = success, 1 = failures)
        def run(paths)
          executor = ParallelSpecExecutor.new(
            worker_count: @worker_count,
            fail_fast:    @fail_fast
          )

          # Build example_id -> worker mapping from discovery
          # This needs to be done before execution to route events to the right worker
          begin
            examples = Parallel::ExampleDiscovery.discover(paths)
            partitions = Parallel::Partitioner.partition(examples, @worker_count)

            partitions.each_with_index do |worker_examples, worker_index|
              next if worker_examples.nil? || worker_examples.empty?
              worker_examples.each do |ex|
                @example_to_worker[ex.id] = worker_index
              end
            end
          rescue Parallel::ExampleDiscovery::DiscoveryError => e
            @output.puts colorize("Error: #{e.message}", :red)
            return 1
          end

          # Wire up event handling
          executor.on_event { |type, event| route_event_to_ui(type, event) }
          executor.on_progress { |c, t, f| @ui.on_progress(completed: c, total: t, failures: f) }

          # Start UI
          @ui.on_run_started(worker_count: @worker_count, example_count: examples.size)
          @ui.start_input_handling

          begin
            # Execute - Async block returns the result of the block
            result = Async do |task|
              executor.execute(paths, task: task)
            end.wait

            # Notify UI of completion
            @ui.on_run_finished(results: result)

            # Print summary
            print_summary(result)
            if @ui.failures.any?
              print_failures
              print_failed_examples_filter
            end

            # Save outputs
            save_outputs(executor.run_data) if @json_path || @html_path

            result&.success? ? 0 : 1
          ensure
            @ui.stop_input_handling
            @ui.cleanup
          end
        end

        private

        def route_event_to_ui(type, event)
          # Get worker index from example_id
          example_id = event.respond_to?(:example_id) ? event.example_id : nil
          worker = example_id ? @example_to_worker[example_id] : 0
          worker ||= 0

          case type
          when "ExampleStarted"
            @ui.on_example_started(worker: worker, event: event)
          when "ExamplePassed", "ExampleFailed", "ExamplePending"
            @ui.on_example_finished(worker: worker, event: event)
          when "GroupStarted", "GroupFinished"
            @ui.on_group_event(worker: worker, event: event)
          when "UserMessage", "AgentResponse", "ToolCallCompleted", "TopicChanged"
            @ui.on_conversation_event(worker: worker, event: event)
          end
        end

        def print_summary(result)
          @output.puts

          return unless result

          parts = ["#{result.example_count} example#{"s" unless result.example_count == 1}"]

          if result.failure_count > 0
            parts << colorize("#{result.failure_count} failure#{"s" unless result.failure_count == 1}", :red)
          else
            parts << colorize("0 failures", :green)
          end

          if result.error
            @output.puts colorize("Error: #{result.error}", :red)
          end

          @output.puts parts.join(", ")
          @output.puts
        end

        def print_failures
          failures = @ui.failures
          return if failures.empty?

          @output.puts colorize("Failures:", :red)
          @output.puts

          failures.each_with_index do |event, i|
            @output.puts "  #{i + 1}) #{event.full_description || event.description}"
            @output.puts "     #{colorize(event.message, :red)}" if event.message
            if event.backtrace&.any?
              event.backtrace.first(3).each do |line|
                @output.puts "     #{colorize(line, :dim)}"
              end
            end
            @output.puts
          end
        end

        def print_failed_examples_filter
          failures = @ui.failures
          return if failures.empty?

          @output.puts colorize("Failed examples:", :red)
          @output.puts

          failures.each do |event|
            location = event.location
            description = event.full_description || event.description
            @output.puts colorize("bin/rspec-agents #{location}", :red) + " " + colorize("# #{description}", :dim)
          end
          @output.puts
        end

        def colorize(text, color)
          return text unless @color
          "#{COLORS[color]}#{text}#{COLORS[:reset]}"
        end

        def save_outputs(run_data)
          return unless run_data

          if @json_path
            FileUtils.mkdir_p(File.dirname(@json_path))
            Serialization::JsonFile.write(@json_path, run_data)
          end

          if @html_path
            Serialization::TestSuiteRenderer.render(run_data, output_path: @html_path)
          end
        end
      end
    end
  end
end

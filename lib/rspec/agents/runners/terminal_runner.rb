# frozen_string_literal: true

require "fileutils"
require_relative "run_data_uploader"

module RSpec
  module Agents
    module Runners
      # Runs RSpec specs sequentially and outputs observer-style notifications to the terminal.
      # Thin adapter over SpecExecutor that handles UI display and output serialization.
      #
      # @example Basic usage
      #   runner = RSpec::Agents::Runners::TerminalRunner.new
      #   exit_code = runner.run(["spec/my_agent_spec.rb"])
      #
      # @example With custom output
      #   runner = RSpec::Agents::Runners::TerminalRunner.new(output: File.open("log.txt", "w"))
      #   runner.run(ARGV)
      #
      class TerminalRunner
        # @param output [IO] Output stream for notifications (default: $stdout)
        # @param color [Boolean] Whether to use ANSI colors (default: true if TTY)
        # @param json_path [String, nil] Path to save JSON run data
        # @param html_path [String, nil] Path to save HTML report
        def initialize(output: $stdout, color: nil, json_path: nil, html_path: nil, upload_url: nil)
          @output = output
          @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color
          @indent = 0
          @json_path = json_path
          @html_path = html_path
          @upload_url = upload_url

          # Set up terminal observer for conversation display
          @event_bus = EventBus.instance
          @event_bus.clear!
          @terminal_observer = Observers::TerminalObserver.new(
            output:    @output,
            color:     @color,
            indent:    2,
            event_bus: @event_bus
          )
        end

        # Run spec files sequentially
        #
        # @param files_or_args [Array<String>] Spec files or RSpec CLI arguments
        # @return [Integer] Exit code (0 = success, 1 = failures)
        def run(files_or_args)
          executor = SequentialSpecExecutor.new

          # Wire up event handling for terminal display
          executor.on_event { |type, event| handle_event(type, event) }

          result = executor.execute(Array(files_or_args))

          # Save outputs after run completes
          save_outputs(executor.run_data) if @json_path || @html_path || @upload_url

          result.success? ? 0 : 1
        end

        private

        def handle_event(type, event)
          # Publish to event bus for TerminalObserver (conversation events)
          @event_bus.publish(event)

          # Handle display for RSpec lifecycle events
          case type
          when "SuiteStarted"
            @output.puts
            @output.puts "#{colorize("▶", :cyan)} Suite started (#{event.example_count} examples)"
            @output.puts
          when "GroupStarted"
            prefix = "  " * @indent
            @output.puts "#{prefix}#{colorize("▼", :blue)} #{event.description}"
            @indent += 1
          when "GroupFinished"
            @indent -= 1
          when "ExampleStarted"
            prefix = "  " * @indent
            @output.print "#{prefix}  #{colorize("○", :white)} #{event.description}..."
            @output.flush
          when "ExamplePassed"
            @output.puts " #{colorize("✓", :green)} #{colorize(format_duration(event.duration), :dim)}"
          when "ExampleFailed"
            prefix = "  " * @indent
            @output.puts " #{colorize("✗", :red)} FAILED"
            if event.message
              event.message.lines.each do |line|
                @output.puts "#{prefix}    #{colorize(line.chomp, :red)}"
              end
            end
            if event.backtrace&.any?
              @output.puts "#{prefix}    #{colorize("Backtrace:", :dim)}"
              event.backtrace.first(3).each do |line|
                @output.puts "#{prefix}      #{colorize(line, :dim)}"
              end
            end
          when "ExamplePending"
            message = event.message
            msg_text = message ? " (#{message})" : ""
            @output.puts " #{colorize("⏸", :yellow)} pending#{msg_text}"
          when "SuiteStopped"
            @output.puts
            @output.puts "#{colorize("■", :cyan)} Suite stopped"
          when "SuiteSummary"
            @output.puts
            summary = build_summary_line(
              example_count: event.example_count,
              failure_count: event.failure_count,
              pending_count: event.pending_count
            )
            @output.puts summary
            @output.puts "Finished in #{format_duration(event.duration)}"
            @output.puts
          end
        end

        def build_summary_line(example_count:, failure_count:, pending_count:)
          parts = []
          parts << "#{example_count} example#{"s" unless example_count == 1}"

          if failure_count > 0
            parts << colorize("#{failure_count} failure#{"s" unless failure_count == 1}", :red)
          else
            parts << colorize("0 failures", :green)
          end

          if pending_count > 0
            parts << colorize("#{pending_count} pending", :yellow)
          end

          parts.join(", ")
        end

        def format_duration(seconds)
          return "0ms" unless seconds

          if seconds < 0.001
            "#{(seconds * 1_000_000).round}µs"
          elsif seconds < 1
            "#{(seconds * 1000).round}ms"
          elsif seconds < 60
            "#{seconds.round(2)}s"
          else
            minutes = (seconds / 60).floor
            secs = (seconds % 60).round(1)
            "#{minutes}m #{secs}s"
          end
        end

        # ANSI color codes
        COLORS = {
          red:     "\e[31m",
          green:   "\e[32m",
          yellow:  "\e[33m",
          blue:    "\e[34m",
          magenta: "\e[35m",
          cyan:    "\e[36m",
          white:   "\e[37m",
          dim:     "\e[2m",
          reset:   "\e[0m"
        }.freeze

        def colorize(text, color)
          return text unless @color
          return text unless COLORS.key?(color)

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

          if @upload_url
            RunDataUploader.new(url: @upload_url, output: @output).upload(run_data)
          end
        end
      end
    end
  end
end

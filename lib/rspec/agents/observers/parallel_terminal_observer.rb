# frozen_string_literal: true

module RSpec
  module Agents
    module Observers
      # Terminal display observer for parallel spec execution.
      # Handles both RSpec lifecycle events and conversation events.
      #
      # Unlike TerminalObserver (used for single-process runs), this observer:
      # - Does not track indentation (parallel examples don't have hierarchy)
      # - Tracks failures for end-of-run summary
      # - Is thread-safe for concurrent event handling
      #
      class ParallelTerminalObserver < Base
        COLORS = {
          red:     "\e[31m",
          green:   "\e[32m",
          yellow:  "\e[33m",
          blue:    "\e[34m",
          magenta: "\e[35m",
          cyan:    "\e[36m",
          dim:     "\e[2m",
          white:   "\e[37m",
          reset:   "\e[0m"
        }.freeze

        attr_reader :failures

        # @param output [IO] Output stream (default: $stdout)
        # @param color [Boolean, nil] Force color on/off (default: auto-detect)
        # @param event_bus [EventBus] Event bus to subscribe to
        def initialize(output: $stdout, color: nil, event_bus:)
          @output = output
          @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color
          @failures = []
          @mutex = Mutex.new
          super(event_bus: event_bus)
        end

        # =======================================================================
        # RSpec Example Lifecycle
        # =======================================================================

        def on_example_started(event)
          @mutex.synchronize do
            desc = event.description || event.full_description
            @output.print "  #{colorize("○", :white)} #{desc}..."
            @output.flush
          end
        end

        def on_example_passed(event)
          @mutex.synchronize do
            duration = format_duration(event.duration)
            @output.puts " #{colorize("✓", :green)} #{colorize(duration, :dim)}"
          end
        end

        def on_example_failed(event)
          @mutex.synchronize do
            @failures << event
            @output.puts " #{colorize("✗", :red)} FAILED"
            if event.message
              event.message.to_s.lines.first(3).each do |line|
                @output.puts "    #{colorize(line.chomp, :red)}"
              end
            end
          end
        end

        def on_example_pending(event)
          @mutex.synchronize do
            message = event.message ? " (#{event.message})" : ""
            @output.puts " #{colorize("⏸", :yellow)} pending#{message}"
          end
        end

        # =======================================================================
        # RSpec Group Lifecycle (describe/context blocks)
        # =======================================================================

        def on_group_started(event)
          @mutex.synchronize do
            @output.puts "  #{colorize("▼", :blue)} #{event.description}"
          end
        end

        def on_group_finished(event)
          # No visual output needed for group end in parallel mode
        end

        # =======================================================================
        # Conversation Events
        # =======================================================================

        def on_user_message(event)
          @mutex.synchronize do
            text = truncate(event.text, 60)
            @output.puts "      #{colorize("User:", :dim)} #{text}"
          end
        end

        def on_agent_response(event)
          @mutex.synchronize do
            text = truncate(event.text, 60)
            @output.puts "      #{colorize("Agent:", :dim)} #{text}"
          end
        end

        def on_tool_call_completed(event)
          @mutex.synchronize do
            args_str = format_tool_args(event.arguments)
            @output.puts "        #{colorize("\u2192", :magenta)} #{colorize(event.tool_name.to_s, :magenta)}#{args_str}"
          end
        end

        def on_topic_changed(event)
          return unless event.from_topic # Skip initial topic set

          @mutex.synchronize do
            @output.puts "      #{colorize("Topic:", :yellow)} #{event.from_topic} → #{event.to_topic}"
          end
        end

        private

        def colorize(text, color)
          return text unless @color
          "#{COLORS[color]}#{text}#{COLORS[:reset]}"
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

        def format_tool_args(arguments)
          return "" if arguments.nil? || arguments.empty?
          args_preview = arguments.map { |k, v| "#{k}: #{truncate(v.to_s, 20)}" }.join(", ")
          colorize("(#{truncate(args_preview, 50)})", :dim)
        end
      end
    end
  end
end

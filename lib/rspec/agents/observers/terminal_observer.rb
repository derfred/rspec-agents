module RSpec
  module Agents
    module Observers
      # Displays conversation events in the terminal
      # Uses box-drawing characters to visualize conversation flow
      class TerminalObserver < Base
        COLORS = {
          user:  "\e[36m",   # cyan
          agent: "\e[32m",  # green
          topic: "\e[33m",  # yellow
          tool:  "\e[35m",   # magenta
          dim:   "\e[2m",
          reset: "\e[0m"
        }.freeze

        # @param output [IO] Output stream (default: $stdout)
        # @param color [Boolean] Whether to use ANSI colors (default: auto-detect TTY)
        # @param indent [Integer] Base indentation level (default: 3)
        def initialize(output: $stdout, color: nil, indent: 3, **options)
          @output = output
          @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color
          @indent = indent
          @current_example_id = nil
          super(**options)
        end

        def on_simulation_started(event)
          @current_example_id = event.example_id
          prefix = "  " * @indent
          @output.puts  # Start on new line after "example_name..."
          goal_preview = truncate(event.goal, 60)
          @output.puts "#{prefix}#{colorize("\u250c", :dim)} Simulation started: #{goal_preview}"
        end

        def on_simulation_ended(event)
          return unless event.example_id == @current_example_id

          prefix = "  " * @indent
          @output.puts "#{prefix}#{colorize("\u2514", :dim)} Simulation ended (#{event.turn_count} turns, #{event.termination_reason})"
        end

        def on_user_message(event)
          prefix = "  " * @indent

          # First user message starts the conversation display (for scripted conversations)
          if @current_example_id != event.example_id
            @current_example_id = event.example_id
            @output.puts  # Start on new line after "example_name..."
            @output.puts "#{prefix}#{colorize("\u250c", :dim)} Conversation started (#{event.source})"
          end

          truncated = truncate(event.text, 80)
          @output.puts "#{prefix}#{colorize("\u2502", :dim)} #{colorize("User:", :user)} #{truncated}"
        end

        def on_agent_response(event)
          return unless event.example_id == @current_example_id

          prefix = "  " * @indent
          truncated = truncate(event.text, 80)
          tool_info = event.tool_calls.any? ? " [#{event.tool_calls.size} tool(s)]" : ""
          @output.puts "#{prefix}#{colorize("\u2502", :dim)} #{colorize("Agent:", :agent)} #{truncated}#{colorize(tool_info, :dim)}"
        end

        def on_tool_call_completed(event)
          return unless event.example_id == @current_example_id

          prefix = "  " * @indent
          args_str = format_tool_args(event.arguments)
          @output.puts "#{prefix}#{colorize("\u2502", :dim)}   #{colorize("\u2192", :tool)} #{colorize(event.tool_name.to_s, :tool)}#{args_str}"
        end

        def on_topic_changed(event)
          return unless event.example_id == @current_example_id
          return unless event.from_topic # Skip initial topic set

          prefix = "  " * @indent
          @output.puts "#{prefix}#{colorize("\u2502", :dim)} #{colorize("Topic:", :topic)} #{event.from_topic} -> #{event.to_topic}"
        end

        private

        def truncate(text, max_length)
          return "" if text.nil?
          text = text.to_s.gsub(/\s+/, " ").strip
          text.length > max_length ? "#{text[0, max_length - 3]}..." : text
        end

        def format_tool_args(arguments)
          return "" if arguments.nil? || arguments.empty?
          args_preview = arguments.map { |k, v| "#{k}: #{truncate(v.to_s, 20)}" }.join(", ")
          colorize("(#{truncate(args_preview, 50)})", :dim)
        end

        def colorize(text, color_name)
          return text unless @color
          return text unless COLORS.key?(color_name)
          "#{COLORS[color_name]}#{text}#{COLORS[:reset]}"
        end
      end
    end
  end
end

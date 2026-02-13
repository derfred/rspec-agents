# frozen_string_literal: true

require_relative "output_adapter"

module RSpec
  module Agents
    module Parallel
      module UI
        # Simple streaming output with worker prefixes.
        # Default for CI environments and non-TTY output.
        #
        # Output format:
        #   [1] o creates user account...
        #   [1]     User: Create an account
        #   [1]     Agent: I'll create that account...
        #   [1]     -> create_user(email: "john@example.com")
        #   [1] v (1.2s)
        #
        class InterleavedUI < OutputAdapter
          attr_reader :failures

          def initialize(output: $stdout, color: true)
            super
            @failures = []
            @worker_count = 0
            @example_count = 0
            @current_examples = {} # worker_index => example_description
          end

          def on_run_started(worker_count:, example_count:)
            @worker_count = worker_count
            @example_count = example_count

            synchronized do
              @output.puts
              @output.puts "#{colorize("\u26a1", :cyan)} Parallel spec runner (#{worker_count} workers)"
              @output.puts
            end
          end

          def on_run_finished(results:)
            # Summary is printed by the runner
          end

          def on_example_started(worker:, event:)
            desc = event.description || event.full_description
            @current_examples[worker] = desc

            synchronized do
              prefix = worker_prefix(worker)
              @output.puts "#{prefix} #{colorize("\u25cb", :white)} #{desc}..."
            end
          end

          def on_example_finished(worker:, event:)
            synchronized do
              prefix = worker_prefix(worker)

              case event
              when Events::ExamplePassed
                duration = format_duration(event.duration)
                @output.puts "#{prefix} #{colorize("\u2713", :green)} #{colorize(duration, :dim)}"

              when Events::ExampleFailed
                @failures << event
                @output.puts "#{prefix} #{colorize("\u2717", :red)} FAILED"
                if event.message
                  event.message.to_s.lines.first(3).each do |line|
                    @output.puts "#{prefix}     #{colorize(line.chomp, :red)}"
                  end
                end
                if event.backtrace&.any?
                  event.backtrace.first(3).each do |line|
                    @output.puts "#{prefix}     #{colorize(line, :dim)}"
                  end
                end

              when Events::ExamplePending
                message = event.message ? " (#{event.message})" : ""
                @output.puts "#{prefix} #{colorize("\u23f8", :yellow)} pending#{message}"
              end
            end

            @current_examples.delete(worker)
          end

          def on_conversation_event(worker:, event:)
            synchronized do
              prefix = worker_prefix(worker)

              case event
              when Events::UserMessage
                text = truncate(event.text, 60)
                @output.puts "#{prefix}     #{colorize("User:", :dim)} #{text}"

              when Events::AgentResponse
                text = truncate(event.text, 60)
                @output.puts "#{prefix}     #{colorize("Agent:", :dim)} #{text}"

              when Events::ToolCallCompleted
                args_str = format_tool_args(event.arguments)
                @output.puts "#{prefix}     #{colorize("\u2192", :magenta)} #{colorize(event.tool_name.to_s, :magenta)}#{args_str}"

              when Events::TopicChanged
                return unless event.from_topic # Skip initial topic set
                @output.puts "#{prefix}     #{colorize("Topic:", :yellow)} #{event.from_topic} \u2192 #{event.to_topic}"
              end
            end
          end

          def on_group_event(worker:, event:)
            synchronized do
              prefix = worker_prefix(worker)

              case event
              when Events::GroupStarted
                @output.puts "#{prefix} #{colorize("\u25bc", :blue)} #{event.description}"
              end
            end
          end

          def on_progress(completed:, total:, failures:)
            # Progress is implicit in the streaming output
          end

          private

          def worker_prefix(worker_index)
            # 1-indexed for display
            num = worker_index + 1
            color = worker_color(worker_index)
            colorize("[#{num}]", color)
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
end

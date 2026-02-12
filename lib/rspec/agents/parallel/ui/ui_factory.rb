# frozen_string_literal: true

require_relative "ui_mode"
require_relative "output_adapter"
require_relative "interactive_ui"
require_relative "interleaved_ui"
require_relative "quiet_ui"

module RSpec
  module Agents
    module Parallel
      module UI
        # Factory for creating UI adapters based on mode selection.
        #
        # @example Auto-select and create adapter
        #   adapter = UIFactory.create(output: $stdout)
        #
        # @example Explicit mode
        #   adapter = UIFactory.create(mode: :interactive, output: $stdout, color: true)
        #
        module UIFactory
          class << self
            # Create an output adapter based on mode
            #
            # @param mode [Symbol, nil] Explicit mode (:interactive, :interleaved, :quiet)
            # @param output [IO] Output stream
            # @param color [Boolean] Enable color output
            # @return [OutputAdapter] Configured adapter
            def create(mode: nil, output: $stdout, color: nil)
              # Auto-detect color if not specified
              color = output.respond_to?(:tty?) && output.tty? if color.nil?

              # Select mode
              selected_mode = UIMode.select(explicit_mode: mode, output: output)

              case selected_mode
              when :interactive
                InteractiveUI.new(output: output, color: color)
              when :interleaved
                InterleavedUI.new(output: output, color: color)
              when :quiet
                QuietUI.new(output: output, color: color)
              else
                # Fallback to interleaved
                InterleavedUI.new(output: output, color: color)
              end
            end
          end
        end
      end
    end
  end
end

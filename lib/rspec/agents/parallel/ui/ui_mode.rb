# frozen_string_literal: true

module RSpec
  module Agents
    module Parallel
      module UI
        # UI mode selection logic for parallel runner.
        # Handles auto-detection based on environment and terminal capabilities.
        #
        # @example Auto-select mode
        #   mode = UIMode.select(output: $stdout)
        #   # => :interactive (if TTY with sufficient size)
        #   # => :interleaved (if non-TTY or CI)
        #
        # @example Explicit mode
        #   mode = UIMode.select(explicit_mode: :quiet, output: $stdout)
        #   # => :quiet
        #
        module UIMode
          MODES = [:interactive, :interleaved, :quiet].freeze

          MIN_COLS = 80
          MIN_ROWS = 24

          class << self
            # Select the appropriate UI mode based on environment and options
            #
            # @param explicit_mode [Symbol, nil] Explicitly requested mode
            # @param output [IO] Output stream
            # @return [Symbol] Selected UI mode
            def select(explicit_mode: nil, output: $stdout)
              return explicit_mode if explicit_mode && MODES.include?(explicit_mode)

              if ci_environment? || !tty?(output)
                :interleaved
              elsif terminal_size_sufficient?
                :interleaved
              else
                :interleaved
              end
            end

            # Parse mode string from CLI flag
            #
            # @param mode_str [String] Mode string ("interactive", "interleaved", "quiet")
            # @return [Symbol, nil] Parsed mode or nil if invalid
            def parse(mode_str)
              return nil unless mode_str
              mode = mode_str.to_sym
              MODES.include?(mode) ? mode : nil
            end

            # Check if running in CI environment
            # @return [Boolean]
            def ci_environment?
              !!(ENV["CI"] || ENV["CONTINUOUS_INTEGRATION"] || ENV["GITHUB_ACTIONS"])
            end

            # Check if output is a TTY
            # @param output [IO]
            # @return [Boolean]
            def tty?(output)
              output.respond_to?(:tty?) && output.tty?
            end

            # Check if terminal has sufficient size for interactive mode
            # @return [Boolean]
            def terminal_size_sufficient?
              cols, rows = terminal_size
              cols >= MIN_COLS && rows >= MIN_ROWS
            end

            # Get terminal size
            # @return [Array<Integer>] [columns, rows]
            def terminal_size
              # Try IO.console first
              if IO.respond_to?(:console) && IO.console
                size = IO.console.winsize rescue nil
                return [size[1], size[0]] if size && size[0] > 0
              end

              # Try stty
              size = `stty size 2>/dev/null`.split.map(&:to_i)
              return [size[1], size[0]] if size.size == 2 && size[0] > 0

              # Try tput
              cols = `tput cols 2>/dev/null`.to_i
              rows = `tput lines 2>/dev/null`.to_i
              return [cols, rows] if cols > 0 && rows > 0

              # Fallback
              [80, 24]
            rescue
              [80, 24]
            end
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "io/console"
require_relative "output_adapter"

module RSpec
  module Agents
    module Parallel
      module UI
        # Full-screen terminal UI with progress tracking and per-worker conversation views.
        # Features tabbed interface, progress bar, keyboard navigation, and auto-follow.
        #
        # Layout:
        #   +-- Progress Header ------------------------------------------+
        #   | Tab Bar: [1 *]   2 o    3 v    4 x         [f]ollow on      |
        #   +-- Content Pane (scrollable) --------------------------------+
        #   |   User: ...                                                 |
        #   |   Agent: ...                                                |
        #   +-- Help Bar -------------------------------------------------+
        #
        class InteractiveUI < OutputAdapter
          # Spinner animation frames (cycles at ~200ms)
          SPINNER_FRAMES = ["\u25d0", "\u25d3", "\u25d1", "\u25d2"].freeze

          # Box drawing characters
          BOX = {
            top_left:             "\u256d",
            top_right:            "\u256e",
            bottom_left:          "\u2570",
            bottom_right:         "\u256f",
            horizontal:           "\u2500",
            vertical:             "\u2502",
            content_top_left:     "\u250c",
            content_top_right:    "\u2510",
            content_bottom_left:  "\u2514",
            content_bottom_right: "\u2518"
          }.freeze

          # Status symbols
          STATUS = {
            running: SPINNER_FRAMES[0],
            idle:    "\u25cb",
            passed:  "\u2713",
            failed:  "\u2717",
            pending: "\u23f8"
          }.freeze

          attr_reader :failures

          # Maximum lines to keep in per-worker buffer
          BUFFER_SIZE = 500

          # Scroll margin (lines from edge before scrolling)
          SCROLL_MARGIN = 3

          def initialize(output: $stdout, color: true)
            super
            @failures = []
            @worker_count = 0
            @example_count = 0
            @completed = 0
            @failure_count = 0

            # Worker state
            @worker_status = {}      # worker_index => :running, :idle, :passed, :failed, :pending
            @worker_examples = {}    # worker_index => current example description
            @worker_buffers = Hash.new { |h, k| h[k] = [] } # worker_index => [lines]
            @worker_finished = {}    # worker_index => example_count finished

            # UI state
            @selected_worker = 0
            @scroll_offset = 0
            @follow_mode = false
            @auto_rotate = false
            @last_switch_time = Time.now
            @spinner_index = 0
            @last_spinner_time = Time.now

            # Terminal state
            @running = false
            @input_thread = nil
            @render_mutex = Mutex.new
            @cols = 80
            @rows = 24
            @run_start_time = nil
          end

          def on_run_started(worker_count:, example_count:)
            @worker_count = worker_count
            @example_count = example_count
            @run_start_time = Time.now

            # Initialize worker state
            worker_count.times do |i|
              @worker_status[i] = :idle
              @worker_examples[i] = nil
              @worker_buffers[i] = []
              @worker_finished[i] = 0
            end

            @running = true
            update_terminal_size
            enter_alternate_screen
            hide_cursor
            render
          end

          def on_run_finished(results:)
            @running = false
            show_cursor
            exit_alternate_screen
          end

          def start_input_handling
            @input_thread = Thread.new { input_loop }
          end

          def stop_input_handling
            @running = false
            @input_thread&.kill
            @input_thread = nil
          end

          def cleanup
            stop_input_handling
            show_cursor
            exit_alternate_screen
          end

          def on_example_started(worker:, event:)
            desc = event.description || event.full_description

            synchronized do
              @worker_status[worker] = :running
              @worker_examples[worker] = desc
              append_to_buffer(worker, "#{colorize("\u25cb", :white)} #{desc}...")

              maybe_switch_to_worker(worker)
              render
            end
          end

          def on_example_finished(worker:, event:)
            synchronized do
              @completed += 1

              case event
              when Events::ExamplePassed
                @worker_status[worker] = :passed
                duration = format_duration(event.duration)
                append_to_buffer(worker, "#{colorize("\u2713", :green)} #{event.description || event.full_description} #{colorize("(#{duration})", :dim)}")

              when Events::ExampleFailed
                @failures << event
                @failure_count += 1
                @worker_status[worker] = :failed
                append_to_buffer(worker, "#{colorize("\u2717", :red)} #{event.description || event.full_description}")
                if event.message
                  event.message.to_s.lines.first(3).each do |line|
                    append_to_buffer(worker, "    #{colorize(line.chomp, :red)}")
                  end
                end
                if event.backtrace&.any?
                  event.backtrace.first(3).each do |line|
                    append_to_buffer(worker, "    #{colorize(line, :dim)}")
                  end
                end

              when Events::ExamplePending
                @worker_status[worker] = :pending
                message = event.message ? " (#{event.message})" : ""
                append_to_buffer(worker, "#{colorize("\u23f8", :yellow)} #{event.description || event.full_description}#{message}")
              end

              @worker_examples[worker] = nil
              @worker_finished[worker] = (@worker_finished[worker] || 0) + 1

              maybe_switch_to_worker(worker)
              render
            end
          end

          def on_conversation_event(worker:, event:)
            synchronized do
              case event
              when Events::UserMessage
                text = truncate(event.text, @cols - 20)
                append_to_buffer(worker, "  #{colorize("User:", :dim)} #{text}")

              when Events::AgentResponse
                text = truncate(event.text, @cols - 20)
                append_to_buffer(worker, "  #{colorize("Agent:", :dim)} #{text}")

              when Events::ToolCallCompleted
                args_str = format_tool_args(event.arguments)
                append_to_buffer(worker, "      #{colorize("\u2192", :magenta)} #{colorize(event.tool_name.to_s, :magenta)}#{args_str}")

              when Events::TopicChanged
                return unless event.from_topic
                append_to_buffer(worker, "  #{colorize("Topic:", :yellow)} #{event.from_topic} \u2192 #{event.to_topic}")
              end

              maybe_switch_to_worker(worker)
              render
            end
          end

          def on_group_event(worker:, event:)
            synchronized do
              case event
              when Events::GroupStarted
                append_to_buffer(worker, "#{colorize("\u25bc", :blue)} #{event.description}")
                render
              end
            end
          end

          def on_progress(completed:, total:, failures:)
            @completed = completed
            @failure_count = failures

            synchronized do
              update_spinner
              render
            end
          end

          private

          # =======================================================================
          # Buffer Management
          # =======================================================================

          def append_to_buffer(worker, line)
            buffer = @worker_buffers[worker]
            buffer << line
            buffer.shift while buffer.size > BUFFER_SIZE

            # Auto-scroll to bottom if in follow mode
            if @follow_mode && worker == @selected_worker
              @scroll_offset = [0, buffer.size - content_height].max
            end
          end

          # =======================================================================
          # Input Handling
          # =======================================================================

          def input_loop
            while @running
              handle_input if IO.select([$stdin], nil, nil, 0.1)
              update_spinner
              render
            end
          rescue
            # Silently ignore input errors during shutdown
          end

          def handle_input
            char = $stdin.getch

            case char
            when "q"
              @running = false
            when "1".."9"
              worker = char.to_i - 1
              select_worker(worker) if worker < @worker_count
            when "h", "\e[D" # left arrow
              select_worker((@selected_worker - 1) % @worker_count)
            when "l", "\e[C" # right arrow
              select_worker((@selected_worker + 1) % @worker_count)
            when "j", "\e[B" # down arrow
              scroll_down
            when "k", "\e[A" # up arrow
              scroll_up
            when "f"
              @follow_mode = !@follow_mode
              @auto_rotate = false if @follow_mode
            when "a"
              @auto_rotate = !@auto_rotate
              @follow_mode = false if @auto_rotate
            when "g"
              scroll_to_top
            when "G"
              scroll_to_bottom
            when "\e" # Escape sequence
              handle_escape_sequence
            end

            render
          rescue Errno::EIO
            # Terminal disconnected
          end

          def handle_escape_sequence
            return unless IO.select([$stdin], nil, nil, 0.05)
            seq = String.new
            2.times do
              break unless IO.select([$stdin], nil, nil, 0.01)
              seq << $stdin.getch
            end

            case seq
            when "[A" then scroll_up
            when "[B" then scroll_down
            when "[C" then select_worker((@selected_worker + 1) % @worker_count)
            when "[D" then select_worker((@selected_worker - 1) % @worker_count)
            when "[5" then page_up    # Page Up
            when "[6" then page_down  # Page Down
            end
          end

          def select_worker(index)
            @selected_worker = index
            @scroll_offset = [0, @worker_buffers[@selected_worker].size - content_height].max
            @last_switch_time = Time.now
          end

          def scroll_up
            @scroll_offset = [@scroll_offset - 1, 0].max
          end

          def scroll_down
            max = [@worker_buffers[@selected_worker].size - content_height, 0].max
            @scroll_offset = [@scroll_offset + 1, max].min
          end

          def page_up
            @scroll_offset = [@scroll_offset - content_height, 0].max
          end

          def page_down
            max = [@worker_buffers[@selected_worker].size - content_height, 0].max
            @scroll_offset = [@scroll_offset + content_height, max].min
          end

          def scroll_to_top
            @scroll_offset = 0
          end

          def scroll_to_bottom
            @scroll_offset = [@worker_buffers[@selected_worker].size - content_height, 0].max
          end

          def maybe_switch_to_worker(worker)
            return unless @follow_mode
            return if Time.now - @last_switch_time < 3 # Don't switch if manually switched recently
            return if @scroll_offset < [@worker_buffers[@selected_worker].size - content_height, 0].max # User scrolled up

            @selected_worker = worker
            @scroll_offset = [@worker_buffers[worker].size - content_height, 0].max
          end

          # =======================================================================
          # Rendering
          # =======================================================================

          def render
            @render_mutex.synchronize do
              update_terminal_size

              output = StringIO.new(String.new)
              output << move_cursor(1, 1)
              output << clear_screen

              render_progress_header(output)
              render_tab_bar(output)
              render_content_pane(output)
              render_help_bar(output)

              @output.print output.string
              @output.flush
            end
          end

          def render_progress_header(output)
            # Progress bar width (leave room for text)
            bar_width = @cols - 50
            bar_width = [bar_width, 20].max

            progress_ratio = @example_count > 0 ? @completed.to_f / @example_count : 0
            filled = (progress_ratio * bar_width).round
            empty = bar_width - filled

            bar = colorize("\u2588" * filled, :cyan) + colorize("\u2591" * empty, :dim)

            status_text = @running ? "Running specs" : "Completed"
            @run_start_time ? format_duration(Time.now - @run_start_time) : ""

            # Build header line
            header = "#{colorize("\u26a1", :cyan)} #{status_text} [#{bar}] #{@completed}/#{@example_count}"
            header += "   #{colorize("#{@failure_count} \u2717", :red)}" if @failure_count > 0
            header += "   #{colorize("#{@completed - @failure_count} \u2713", :green)}" if @completed > 0
            header += "   #{@worker_count} workers"

            # Draw boxed header
            output << BOX[:top_left] + BOX[:horizontal] * (@cols - 2) + BOX[:top_right] + "\n"
            output << BOX[:vertical] + " " + pad_or_truncate(header, @cols - 4) + " " + BOX[:vertical] + "\n"
            output << BOX[:bottom_left] + BOX[:horizontal] * (@cols - 2) + BOX[:bottom_right] + "\n"
          end

          def render_tab_bar(output)
            tabs = []
            @worker_count.times do |i|
              status = @worker_status[i]
              symbol = status == :running ? spinner_char : STATUS[status]
              color = status_color(status)

              if i == @selected_worker
                tabs << "[#{colorize("#{i + 1}", :bold)} #{colorize(symbol, color)}]"
              else
                tabs << " #{i + 1} #{colorize(symbol, color)} "
              end
            end

            mode_indicator = if @follow_mode
                               "[#{colorize("f", :bold)}]ollow on"
                             elsif @auto_rotate
                               "[#{colorize("a", :bold)}]uto-rotate"
                             else
                               "[#{colorize("f", :dim)}]ollow off"
                             end

            tab_line = tabs.join("  ")
            padding = @cols - visible_length(tab_line) - visible_length(mode_indicator) - 2
            padding = [padding, 1].max

            output << "\n " << tab_line << " " * padding << mode_indicator << "\n\n"
          end

          def render_content_pane(output)
            worker = @selected_worker
            example = @worker_examples[worker]
            buffer = @worker_buffers[worker]
            finished = @worker_finished[worker] || 0

            # Header
            header = "Worker #{worker + 1}"
            header += ": #{example}" if example
            header = truncate(header, @cols - 6)

            output << BOX[:content_top_left] + BOX[:horizontal] + " " + header + " "
            output << BOX[:horizontal] * (@cols - visible_length(header) - 6) + BOX[:content_top_right] + "\n"

            # Content
            height = content_height
            visible_lines = buffer[@scroll_offset, height] || []

            if visible_lines.empty?
              # Show waiting message
              empty_lines = (height - 3) / 2
              empty_lines.times { output << BOX[:vertical] + " " * (@cols - 2) + BOX[:vertical] + "\n" }

              if finished > 0
                msg = "\u2713 Worker finished (#{finished} example#{"s" unless finished == 1})"
                output << BOX[:vertical] + center_text(colorize(msg, :green), @cols - 2) + BOX[:vertical] + "\n"
              else
                msg = "Waiting for next example..."
                output << BOX[:vertical] + center_text(colorize(msg, :dim), @cols - 2) + BOX[:vertical] + "\n"
              end

              remaining = height - empty_lines - 1
              remaining.times { output << BOX[:vertical] + " " * (@cols - 2) + BOX[:vertical] + "\n" }
            else
              visible_lines.each do |line|
                truncated = truncate_line(line, @cols - 4)
                padding = @cols - 4 - visible_length(truncated)
                output << BOX[:vertical] + " " + truncated + " " * [padding, 0].max + " " + BOX[:vertical] + "\n"
              end

              # Pad remaining lines
              (height - visible_lines.size).times do
                output << BOX[:vertical] + " " * (@cols - 2) + BOX[:vertical] + "\n"
              end
            end

            output << BOX[:content_bottom_left] + BOX[:horizontal] * (@cols - 2) + BOX[:content_bottom_right] + "\n"
          end

          def render_help_bar(output)
            help = " 1-#{@worker_count} switch \u00b7 \u2190\u2192 prev/next \u00b7 \u2191\u2193 scroll \u00b7 f follow \u00b7 a auto-rotate \u00b7 q quit"
            output << colorize(truncate(help, @cols), :dim)
          end

          # =======================================================================
          # Terminal Control
          # =======================================================================

          def update_terminal_size
            size = IO.console&.winsize rescue nil
            if size && size[0] > 0
              @rows = size[0]
              @cols = size[1]
            end
          end

          def content_height
            # Total height minus: header(3) + blank(1) + tabs(2) + blank(1) + content border(2) + help(1)
            [@rows - 10, 5].max
          end

          def enter_alternate_screen
            @output.print "\e[?1049h"
          end

          def exit_alternate_screen
            @output.print "\e[?1049l"
          end

          def hide_cursor
            @output.print "\e[?25l"
          end

          def show_cursor
            @output.print "\e[?25h"
          end

          def move_cursor(row, col)
            "\e[#{row};#{col}H"
          end

          def clear_screen
            "\e[2J"
          end

          # =======================================================================
          # Helpers
          # =======================================================================

          def update_spinner
            now = Time.now
            if now - @last_spinner_time >= 0.2
              @spinner_index = (@spinner_index + 1) % SPINNER_FRAMES.size
              @last_spinner_time = now
            end
          end

          def spinner_char
            SPINNER_FRAMES[@spinner_index]
          end

          def status_color(status)
            case status
            when :running then :cyan
            when :passed then :green
            when :failed then :red
            when :pending then :yellow
            else :white
            end
          end

          def pad_or_truncate(text, width)
            visible = visible_length(text)
            if visible > width
              truncate_line(text, width)
            else
              text + " " * (width - visible)
            end
          end

          def center_text(text, width)
            visible = visible_length(text)
            return truncate_line(text, width) if visible > width

            padding = (width - visible) / 2
            " " * padding + text + " " * (width - visible - padding)
          end

          def truncate_line(line, max_width)
            return "" unless line
            visible = 0
            result = String.new
            in_escape = false

            line.each_char do |char|
              if char == "\e"
                in_escape = true
                result << char
              elsif in_escape
                result << char
                in_escape = false if char =~ /[a-zA-Z]/
              else
                break if visible >= max_width - 3 && visible_length(line) > max_width
                result << char
                visible += 1
              end
            end

            if visible_length(line) > max_width
              result + "..."
            else
              result
            end
          end

          def visible_length(text)
            # Remove ANSI escape sequences to get visible length
            text.to_s.gsub(/\e\[[0-9;]*[a-zA-Z]/, "").length
          end

          def format_tool_args(arguments)
            return "" if arguments.nil? || arguments.empty?
            args_preview = arguments.map { |k, v| "#{k}: #{truncate(v.to_s, 20)}" }.join(", ")
            colorize("(#{truncate(args_preview, 40)})", :dim)
          end
        end
      end
    end
  end
end

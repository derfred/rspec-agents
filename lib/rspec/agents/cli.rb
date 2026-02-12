# frozen_string_literal: true

require "optparse"

module RSpec
  module Agents
    # Unified CLI for rspec-agents
    #
    # Commands:
    #   run      - Single-process execution (default)
    #   parallel - Parallel execution with worker processes
    #   worker   - Internal: run as a worker subprocess
    #
    # @example Single process
    #   CLI.run(["spec/"])
    #   CLI.run(["run", "spec/"])
    #
    # @example Parallel
    #   CLI.run(["parallel", "-w", "4", "spec/"])
    #
    # @example Worker (internal)
    #   CLI.run(["worker"])
    #
    class CLI
      COMMANDS = %w[run parallel worker render].freeze

      def self.run(argv)
        new(argv).run
      end

      def initialize(argv)
        @argv = argv.dup
      end

      def run
        command, args = parse_command(@argv)

        case command
        when "run"
          run_single(args)
        when "parallel"
          run_parallel(args)
        when "worker"
          run_worker(args)
        when "render"
          run_render(args)
        else
          # Default to single-process run
          run_single(@argv)
        end
      end

      private

      def parse_command(argv)
        return [nil, argv] if argv.empty?

        first = argv.first

        # Auto-detect parallel mode if -w/--workers flag is present
        if has_parallel_flag?(argv)
          # If first arg is explicit command, consume it; otherwise keep all args
          if COMMANDS.include?(first)
            return ["parallel", argv[1..]]
          else
            return ["parallel", argv]
          end
        end

        # Original logic for explicit commands or default to single-process
        if COMMANDS.include?(first)
          [first, argv[1..]]
        elsif first.start_with?("-")
          # Flag, not a command - default to run
          [nil, argv]
        else
          # Path or unknown - default to run
          [nil, argv]
        end
      end

      def has_parallel_flag?(argv)
        argv.any? { |arg| arg == "-w" || arg.start_with?("--workers") }
      end

      # =========================================================================
      # Single-process mode
      # =========================================================================

      def run_single(args)
        options = parse_single_options(args)

        runner = Runners::TerminalRunner.new(
          output:    $stdout,
          color:     options[:color],
          json_path: options[:json_path],
          html_path: options[:html_path]
        )
        runner.run(options[:paths])
      end

      def parse_single_options(args)
        options = { paths: [], color: nil, json_path: nil, html_path: nil }

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rspec-agents [run] [options] [paths...]"
          opts.separator ""
          opts.separator "Run specs in a single process with terminal output."
          opts.separator ""
          opts.separator "Options:"

          opts.on("--[no-]color", "Force color on/off (default: auto)") do |v|
            options[:color] = v
          end

          opts.on("--ui MODE", [:interactive, :interleaved, :quiet],
                  "Output mode (ignored in single-process mode)") do |_mode|
            # Accepted for CLI compatibility with parallel mode, but ignored
          end

          opts.on("--json PATH", "Save JSON run data to file") do |path|
            options[:json_path] = path
          end

          opts.on("--html PATH", "Render HTML report to path") do |path|
            options[:html_path] = path
          end

          opts.on("-h", "--help", "Show this help") do
            puts opts
            exit 0
          end
        end

        remaining = parser.parse(args)
        options[:paths] = remaining.empty? ? ["spec"] : remaining
        options
      end

      # =========================================================================
      # Parallel mode
      # =========================================================================

      def run_parallel(args)
        options = parse_parallel_options(args)

        runner = Runners::ParallelTerminalRunner.new(
          worker_count: options[:workers],
          fail_fast:    options[:fail_fast],
          output:       $stdout,
          color:        options[:color],
          json_path:    options[:json_path],
          html_path:    options[:html_path],
          ui_mode:      options[:ui_mode]
        )
        runner.run(options[:paths])
      end

      def parse_parallel_options(args)
        options = {
          workers:   4,
          fail_fast: false,
          paths:     [],
          color:     nil,
          json_path: nil,
          html_path: nil,
          ui_mode:   nil
        }

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rspec-agents parallel [options] [paths...]"
          opts.separator ""
          opts.separator "Run specs in parallel across multiple worker processes."
          opts.separator ""
          opts.separator "Options:"

          opts.on("-w", "--workers COUNT", Integer, "Number of workers (default: 4)") do |w|
            options[:workers] = w
          end

          opts.on("--fail-fast", "Stop on first failure") do
            options[:fail_fast] = true
          end

          opts.on("--[no-]color", "Force color on/off (default: auto)") do |v|
            options[:color] = v
          end

          opts.on("--ui MODE", [:interactive, :interleaved, :quiet],
                  "Output mode: interactive, interleaved, quiet (default: auto)") do |mode|
            options[:ui_mode] = mode
          end

          opts.on("--json PATH", "Save JSON run data to file") do |path|
            options[:json_path] = path
          end

          opts.on("--html PATH", "Render HTML report to path") do |path|
            options[:html_path] = path
          end

          opts.on("-h", "--help", "Show this help") do
            puts opts
            exit 0
          end
        end

        remaining = parser.parse(args)
        options[:paths] = remaining.empty? ? ["spec"] : remaining
        options
      end

      # =========================================================================
      # Worker mode (internal - used by parallel controller)
      # =========================================================================

      def run_worker(_args)
        require "json"

        # Get RPC socket from environment
        fd_str = ENV["RPC_SOCKET_FD"]
        unless fd_str
          $stderr.puts("ERROR: RPC_SOCKET_FD not set (worker mode requires controller)")
          exit 1
        end

        fd = fd_str.to_i
        socket = IO.for_fd(fd, mode: "r+")
        socket.sync = true

        worker_index = ENV["WORKER_INDEX"] || "?"
        $stderr.puts("[worker-#{worker_index}] started")

        runner = nil
        running = true

        while running && (line = socket.gets)
          begin
            handle_worker_message(socket, line, worker_index) do |example_ids|
              runner ||= Runners::HeadlessRunner.new(rpc_output: socket)
              runner.run(example_ids)
            end
          rescue JSON::ParserError => e
            $stderr.puts("[worker-#{worker_index}] JSON parse error: #{e.message}")
          rescue => e
            $stderr.puts("[worker-#{worker_index}] Error: #{e.class}: #{e.message}")
            $stderr.puts(e.backtrace.first(5).join("\n"))
          end
        end

        $stderr.puts("[worker-#{worker_index}] exiting")
        0
      end

      def handle_worker_message(socket, line, worker_index)
        msg = JSON.parse(line.chomp, symbolize_names: true)

        case msg[:action]
        when "__shutdown__"
          send_worker_response(socket, msg[:id], { status: "shutting_down" })
          return false # Signal to stop

        when "run_specs"
          $stderr.puts("[worker-#{worker_index}] running #{msg[:example_ids]&.size || 0} examples")
          result = yield(msg[:example_ids] || [])
          send_worker_response(socket, msg[:id], result)

        else
          send_worker_response(socket, msg[:id], { error: "unknown action: #{msg[:action]}" })
        end

        true # Continue running
      end

      def send_worker_response(socket, request_id, payload)
        response = payload.merge(reply_to: request_id)
        socket.puts(response.to_json)
        socket.flush
      end

      # =========================================================================
      # Render mode - generate HTML report from JSON file
      # =========================================================================

      def run_render(args)
        options = parse_render_options(args)

        unless options[:json_path]
          $stderr.puts("Error: JSON file path is required")
          $stderr.puts("Usage: rspec-agents render <json_file> [--html PATH]")
          return 1
        end

        unless File.exist?(options[:json_path])
          $stderr.puts("Error: JSON file not found: #{options[:json_path]}")
          return 1
        end

        output_path = Serialization::TestSuiteRenderer.from_json_file(
          options[:json_path],
          output_path: options[:html_path]
        )

        if output_path
          puts "HTML report written to: #{output_path}"
          0
        else
          $stderr.puts("Error: Failed to render HTML report")
          1
        end
      end

      def parse_render_options(args)
        options = { json_path: nil, html_path: nil }

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rspec-agents render <json_file> [options]"
          opts.separator ""
          opts.separator "Render an HTML report from a JSON run file."
          opts.separator ""
          opts.separator "Options:"

          opts.on("--html PATH", "Output HTML path (default: tmp/rspec_agents_debug.html)") do |path|
            options[:html_path] = path
          end

          opts.on("-h", "--help", "Show this help") do
            puts opts
            exit 0
          end
        end

        remaining = parser.parse(args)
        options[:json_path] = remaining.first
        options
      end
    end

    # Zeitwerk expects cli.rb to define Cli, but we use CLI (conventional for command-line interfaces)
    Cli = CLI
  end
end

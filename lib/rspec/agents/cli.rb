# frozen_string_literal: true

require "optparse"

module RSpec
  module Agents
    # Unified CLI for rspec-agents
    #
    # Subcommands:
    #   render  - Generate HTML report from JSON file
    #   worker  - Internal: run as a worker subprocess
    #
    # Without a subcommand, runs specs directly. Pass -w/--workers to
    # enable parallel execution.
    #
    # @example Single process
    #   CLI.run(["spec/"])
    #
    # @example Parallel
    #   CLI.run(["-w", "4", "spec/"])
    #
    # @example Worker (internal)
    #   CLI.run(["worker"])
    #
    class CLI
      SUBCOMMANDS = %w[worker render].freeze

      def self.run(argv)
        new(argv).run
      end

      def initialize(argv)
        @argv = argv.dup
      end

      def run
        command, args = extract_subcommand(@argv)

        case command
        when "worker"
          run_worker(args)
        when "render"
          run_render(args)
        else
          run_specs(args)
        end
      end

      private

      def extract_subcommand(argv)
        return [nil, argv] if argv.empty?

        first = argv.first
        if SUBCOMMANDS.include?(first)
          [first, argv[1..]]
        else
          [nil, argv]
        end
      end

      # =========================================================================
      # Spec execution (single-process or parallel via -w)
      # =========================================================================

      def run_specs(args)
        options = parse_run_options(args)

        if options[:workers]
          runner = Runners::ParallelTerminalRunner.new(
            worker_count: options[:workers],
            fail_fast:    options[:fail_fast],
            output:       $stdout,
            color:        options[:color],
            json_path:    options[:json_path],
            html_path:    options[:html_path],
            ui_mode:      options[:ui_mode],
            upload_url:   options[:upload_url]
          )
        else
          runner = Runners::TerminalRunner.new(
            output:     $stdout,
            color:      options[:color],
            json_path:  options[:json_path],
            html_path:  options[:html_path],
            upload_url: options[:upload_url]
          )
        end

        runner.run(options[:paths])
      end

      def parse_run_options(args)
        options = {
          paths:     [],
          workers:   nil,
          fail_fast: false,
          color:     nil,
          json_path: nil,
          html_path: nil,
          ui_mode:   nil,
          upload_url: nil
        }

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rspec-agents [options] [paths...]"
          opts.separator ""
          opts.separator "Run specs with terminal output. Pass -w to run in parallel."
          opts.separator ""
          opts.separator "Options:"

          opts.on("-w", "--workers COUNT", Integer, "Run in parallel with COUNT workers") do |w|
            options[:workers] = w
          end

          opts.on("--fail-fast", "Stop on first failure (parallel mode)") do
            options[:fail_fast] = true
          end

          opts.on("--[no-]color", "Force color on/off (default: auto)") do |v|
            options[:color] = v
          end

          opts.on("--ui MODE", [:interactive, :interleaved, :quiet],
                  "Output mode: interactive, interleaved, quiet (parallel mode, default: auto)") do |mode|
            options[:ui_mode] = mode
          end

          opts.on("--json PATH", "Save JSON run data to file") do |path|
            options[:json_path] = path
          end

          opts.on("--html PATH", "Render HTML report to path") do |path|
            options[:html_path] = path
          end

          opts.on("--upload [URL]", "Upload run data to agents-studio (default: http://localhost:9292)") do |url|
            options[:upload_url] = url || "http://localhost:9292"
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

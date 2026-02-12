# frozen_string_literal: true

require "async"
require_relative "../../../lib/async_workers"

RSpec.describe "Unix Socket Transport" do
  let(:unix_socket_worker_path) { File.expand_path("../support/unix_socket_worker.rb", __dir__) }
  let(:command) { ["ruby", unix_socket_worker_path] }

  describe "socket communication" do
    it "performs RPC over unix socket" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "echo", data: "socket test" })
        expect(response[:result]).to eq("socket test")

        process.stop
      end
    end

    it "performs arithmetic via RPC" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "add", a: 100, b: 200 })
        expect(response[:result]).to eq(300)

        process.stop
      end
    end

    it "handles multiple concurrent requests" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        process.start(task: task)

        results = Async do |inner|
          tasks = 5.times.map do |i|
            inner.async do
              process.rpc.request({ action: "add", a: i, b: i * 10 })
            end
          end
          tasks.map(&:wait)
        end.wait

        expect(results.map { |r| r[:result] }).to contain_exactly(0, 11, 22, 33, 44)

        process.stop
      end
    end
  end

  describe "FD inheritance" do
    it "child receives valid RPC_SOCKET_FD" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "env" })
        expect(response.dig(:result, :rpc_socket_fd)).not_to be_nil
        expect(response.dig(:result, :rpc_socket_fd).to_i).to be > 0

        process.stop
      end
    end
  end

  describe "stdout separation" do
    it "captures stdout separately from RPC" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        stdout_lines = []
        process.stdout.on_data { |line| stdout_lines << line }
        process.start(task: task)

        # Poll for worker startup message on stdout
        20.times do
          break if stdout_lines.any? { |l| l.include?("unix_socket_worker started") }
          sleep 0.1
        end

        # Should see the startup message
        expect(stdout_lines.any? { |l| l.include?("unix_socket_worker started") }).to be true

        # Do RPC
        response = process.rpc.request({ action: "log_to_stdout", message: "test stdout" })
        expect(response[:result]).to eq("logged_to_stdout")

        10.times do
          break if stdout_lines.any? { |l| l.include?("stdout: test stdout") }
          sleep 0.1
        end
        expect(stdout_lines.any? { |l| l.include?("stdout: test stdout") }).to be true

        process.stop
      end
    end

    it "RPC works while stdout streams" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        stdout_lines = []
        process.stdout.on_data { |line| stdout_lines << line }
        process.start(task: task)

        # Interleave stdout and RPC
        response1 = process.rpc.request({ action: "log_to_stdout", message: "msg1" })
        response2 = process.rpc.request({ action: "add", a: 1, b: 2 })
        response3 = process.rpc.request({ action: "log_to_stdout", message: "msg2" })

        expect(response1[:result]).to eq("logged_to_stdout")
        expect(response2[:result]).to eq(3)
        expect(response3[:result]).to eq("logged_to_stdout")

        sleep 0.1
        expect(stdout_lines.any? { |l| l.include?("msg1") }).to be true
        expect(stdout_lines.any? { |l| l.include?("msg2") }).to be true

        process.stop
      end
    end
  end

  describe "stderr separation" do
    it "captures stderr separately from RPC" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)

        # Worker outputs "worker ready" to stderr
        sleep 1.0
        expect(stderr_lines.any? { |l| l.include?("worker ready") }).to be true

        # Request stderr output
        response = process.rpc.request({ action: "log_to_stderr", message: "test stderr" })
        expect(response[:result]).to eq("logged_to_stderr")

        sleep 0.1
        expect(stderr_lines.any? { |l| l.include?("stderr: test stderr") }).to be true

        process.stop
      end
    end
  end

  describe "notifications over socket" do
    it "receives notifications via socket transport" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        notifications = []
        process.start(task: task)
        process.rpc.on_notification { |n| notifications << n }

        process.rpc.request({ action: "notify_progress", count: 3 })

        sleep 0.5

        expect(notifications.size).to eq(3)
        expect(notifications.map { |n| n[:percent] }).to eq([33, 67, 100])

        process.stop
      end
    end
  end

  describe "graceful shutdown" do
    it "shuts down cleanly via socket" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
        )

        process.start(task: task)
        expect(process.alive?).to be true

        process.stop(timeout: 5)

        expect(process.status).to eq(:exited)
        expect(process.exit_status.success?).to be true
      end
    end
  end
end

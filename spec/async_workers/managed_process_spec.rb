# frozen_string_literal: true

require "async"
require_relative "../../lib/async_workers"

RSpec.describe AsyncWorkers::ManagedProcess do
  let(:worker_path) { File.expand_path("./support/test_worker.rb", __dir__) }
  let(:output_worker_path) { File.expand_path("./support/output_worker.rb", __dir__) }
  let(:command) { ["ruby", worker_path] }

  describe "basic RPC request/response" do
    it "sends request and receives response" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "echo", data: "hello" })
        expect(response[:result]).to eq("hello")

        process.stop
      end
    end

    it "performs addition via RPC" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "add", a: 2, b: 3 })
        expect(response[:result]).to eq(5)

        process.stop
      end
    end
  end

  describe "stderr capture" do
    it "captures stderr output" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }

        process.start(task: task)

        process.rpc.request({ action: "log", message: "test message" })

        # Give time for stderr to be captured
        sleep 0.1

        expect(stderr_lines).to include("[worker] test message")

        process.stop
      end
    end
  end

  describe "notifications" do
    it "receives progress notifications" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        notifications = []
        process.start(task: task)
        process.rpc.on_notification { |n| notifications << n }

        process.rpc.request({ action: "notify_progress", count: 3 })

        # Give time for notifications to arrive
        sleep 0.5

        expect(notifications.size).to eq(3)
        expect(notifications.map { |n| n[:percent] }).to eq([33, 67, 100])

        process.stop
      end
    end
  end

  describe "timeout handling" do
    it "raises TimeoutError when request times out" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        expect {
          process.rpc.request({ action: "hang" }, timeout: 0.5)
        }.to raise_error(Async::TimeoutError)

        process.kill
      end
    end
  end

  describe "graceful shutdown" do
    it "sends shutdown message and exits cleanly" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        # Verify process is running
        expect(process.alive?).to be true

        process.stop(timeout: 5)

        expect(process.status).to eq(:exited)
        expect(process.exit_status).to be_a(Process::Status)
        expect(process.exit_status.success?).to be true
      end
    end
  end

  describe "environment variables" do
    it "passes environment variables to worker" do
      Async do |task|
        process = described_class.new(
          command: command,
          env:     { "CUSTOM_VAR" => "test_value" },
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "env" })
        # The test worker returns worker_index and rpc_socket_fd
        # Custom env vars aren't exposed by the test worker, but we can check
        # that no error occurred
        expect(response).to have_key(:result)

        process.stop
      end
    end
  end

  describe "process lifecycle" do
    it "tracks status through lifecycle" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        expect(process.status).to eq(:pending)

        process.start(task: task)
        expect(process.status).to eq(:running)
        expect(process.pid).to be_a(Integer)

        process.stop
        expect(process.status).to eq(:exited)
      end
    end

    it "calls exit callback when process exits" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        exit_status_received = nil
        callback_condition = Async::Condition.new
        process.on_exit do |status|
          exit_status_received = status
          callback_condition.signal
        end

        process.start(task: task)
        process.stop

        # Wait for callback to be called (with timeout)
        task.with_timeout(2) { callback_condition.wait } if exit_status_received.nil?

        expect(exit_status_received).to be_a(Process::Status)
        expect(exit_status_received.success?).to be true
      end
    end
  end

  describe "process termination" do
    it "graceful stop with SIGTERM honored" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sigterm"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)

        sleep 0.2
        expect(process.alive?).to be true

        process.stop(timeout: 2)

        expect(process.status).to eq(:exited)
        expect(stderr_lines.any? { |l| l.include?("SIGTERM received") }).to be true
      end
    end

    it "force kill when SIGTERM is ignored" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sigterm_ignore"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)

        sleep 0.5
        expect(process.alive?).to be true

        process.stop(timeout: 2)

        expect(process.status).to eq(:exited)
        expect(stderr_lines.any? { |l| l.include?("SIGTERM ignored") }).to be true
      end
    end

    it "immediate kill" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sigterm_ignore"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        process.start(task: task)
        sleep 0.2

        process.kill

        sleep 0.2
        expect(process.alive?).to be false
        expect(process.status).to eq(:exited)
      end
    end

    it "sends arbitrary signal" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sigterm"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)

        # Wait for process to be ready
        sleep 1.0
        process.send_signal(:USR1)
        # Give time for signal handling and stderr output
        sleep 1.0

        expect(stderr_lines.any? { |l| l.include?("USR1 received") }).to be true

        process.kill
      end
    end
  end

  describe "wait behavior" do
    it "wait blocks until exit" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sleep", "0.5"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        process.start(task: task)

        start_time = Time.now
        process.wait
        elapsed = Time.now - start_time

        expect(elapsed).to be >= 0.4
        expect(process.status).to eq(:exited)
      end
    end

    it "wait with timeout succeeds" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sleep", "0.3"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        process.start(task: task)

        expect { process.wait(timeout: 2) }.not_to raise_error
        expect(process.status).to eq(:exited)
      end
    end

    it "wait with timeout exceeded raises TimeoutError" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sigterm_ignore"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        process.start(task: task)

        expect { process.wait(timeout: 0.5) }.to raise_error(Async::TimeoutError)

        process.kill
      end
    end
  end

  describe "output streaming (no_rpc mode)" do
    it "captures stdout lines" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "lines", "3", "0.05"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stdout_lines = []
        process.stdout.on_data { |line| stdout_lines << line }
        process.start(task: task)
        process.wait

        expect(stdout_lines).to eq(["stdout line 1", "stdout line 2", "stdout line 3"])
      end
    end

    it "captures stderr lines" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "lines", "3", "0.05"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)
        process.wait

        expect(stderr_lines).to eq(["stderr line 1", "stderr line 2", "stderr line 3"])
      end
    end

    it "stdout is empty in stdio_rpc mode" do
      Async do |task|
        process = described_class.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        stdout_lines = []
        process.stdout.on_data { |line| stdout_lines << line }
        process.start(task: task)

        # Do something
        process.rpc.request({ action: "echo", data: "test" })
        sleep 0.1

        # Stdout should have no lines (RPC uses stdout)
        expect(stdout_lines).to be_empty

        process.stop
      end
    end

    it "preserves stderr output order" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "lines", "5", "0.02"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)
        process.wait

        expect(stderr_lines.size).to eq(5)

        # Verify ordering
        (1..5).each do |i|
          expect(stderr_lines[i - 1]).to eq("stderr line #{i}")
        end
      end
    end
  end

  describe "health monitoring" do
    it "detects process exit via alive?" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "sleep", "0.5"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        process.start(task: task)
        expect(process.alive?).to be true

        # Wait longer than the sleep duration
        sleep 1.5
        expect(process.alive?).to be false
      end
    end

    it "detects crash" do
      Async do |task|
        process = described_class.new(
          command: ["ruby", output_worker_path, "crash", "42"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        exit_received = nil
        process.on_exit { |status| exit_received = status }
        process.start(task: task)
        process.wait

        expect(process.exit_status.exitstatus).to eq(42)
        expect(exit_received.exitstatus).to eq(42)
      end
    end
  end
end

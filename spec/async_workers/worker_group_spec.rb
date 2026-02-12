# frozen_string_literal: true

require "async"
require_relative "../../lib/async_workers"

RSpec.describe AsyncWorkers::WorkerGroup do
  let(:worker_path) { File.expand_path("./support/test_worker.rb", __dir__) }
  let(:command) { ["ruby", worker_path] }

  describe "basic operation" do
    it "spawns multiple workers" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        expect(group.size).to eq(3)
        expect(group.workers.size).to eq(3)
        expect(group.alive?).to be true

        group.stop
      end
    end

    it "provides array access to workers" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        expect(group[0]).to be_a(AsyncWorkers::ManagedProcess)
        expect(group[1]).to be_a(AsyncWorkers::ManagedProcess)

        group.stop
      end
    end

    it "includes Enumerable" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        pids = group.map(&:pid)
        expect(pids.size).to eq(2)
        expect(pids.all? { |p| p.is_a?(Integer) }).to be true

        group.stop
      end
    end
  end

  describe "WORKER_INDEX environment" do
    it "passes correct index to each worker" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        indices = group.map do |worker|
          response = worker.rpc.request({ action: "env" })
          response.dig(:result, :worker_index)
        end

        expect(indices).to eq(["0", "1", "2"])

        group.stop
      end
    end
  end

  describe "fan-out work" do
    it "distributes work to multiple workers" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        results = Async do |inner|
          tasks = group.workers.map.with_index do |worker, i|
            inner.async do
              worker.rpc.request({ action: "add", a: i, b: 10 })
            end
          end
          tasks.map(&:wait)
        end.wait

        expect(results.map { |r| r[:result] }).to eq([10, 11])

        group.stop
      end
    end
  end

  describe "fail-fast behavior" do
    it "kills all workers when one fails" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        # Cause worker 1 to crash
        group[1].rpc.notify({ action: "crash", code: 1 })

        # Wait for failure detection
        failure = group.wait_for_failure

        expect(failure).to be_a(AsyncWorkers::WorkerFailure)
        expect(failure.worker_index).to eq(1)
        expect(group.failed?).to be true

        # Give time for cleanup - the kill signal needs time to propagate
        sleep 1.0

        # Other workers should be killed
        expect(group[0].alive?).to be false
        expect(group[2].alive?).to be false
      end
    end

    it "records the failure" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)
        expect(group.failed?).to be false

        # Cause worker 0 to crash
        group[0].rpc.notify({ action: "crash", code: 42 })

        group.wait_for_failure

        expect(group.failed?).to be true
        expect(group.failure.worker_index).to eq(0)
        expect(group.failure.exit_status.exitstatus).to eq(42)
      end
    end
  end

  describe "wait" do
    let(:output_worker_path) { File.expand_path("./support/output_worker.rb", __dir__) }

    it "blocks until all workers exit" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: ["ruby", output_worker_path, "sleep", "0.3"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        group.start(task: task)

        start_time = Time.now
        statuses = group.wait
        elapsed = Time.now - start_time

        expect(elapsed).to be >= 0.2
        expect(statuses.size).to eq(2)
        expect(statuses.all? { |s| s.is_a?(Process::Status) }).to be true
        expect(group.alive?).to be false
      end
    end

    it "returns exit statuses from all workers" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: ["ruby", output_worker_path, "sleep", "0.1"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        group.start(task: task)

        statuses = group.wait

        expect(statuses.all?(&:success?)).to be true
      end
    end

    it "raises TimeoutError when timeout exceeded" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: ["ruby", output_worker_path, "sigterm_ignore"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        group.start(task: task)

        expect { group.wait(timeout: 0.3) }.to raise_error(Async::TimeoutError)

        group.kill
      end
    end

    it "succeeds within timeout" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: ["ruby", output_worker_path, "sleep", "0.2"],
          rpc:     AsyncWorkers::ChannelConfig.no_rpc
        )

        group.start(task: task)

        expect { group.wait(timeout: 2) }.not_to raise_error
        expect(group.alive?).to be false
      end
    end
  end

  describe "graceful shutdown" do
    it "stops all workers gracefully" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)
        expect(group.alive?).to be true

        group.stop(timeout: 5)

        expect(group.alive?).to be false
        group.each do |worker|
          expect(worker.status).to eq(:exited)
        end
      end
    end

    it "kills all workers immediately" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)
        expect(group.alive?).to be true

        group.kill

        sleep 0.2
        expect(group.alive?).to be false
      end
    end
  end

  describe "conditional failure" do
    it "fails specific worker based on FAIL_INDEX" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          env:     { "FAIL_INDEX" => "1" },
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        # Trigger conditional failure on all workers
        # Only worker 1 should fail (its WORKER_INDEX matches FAIL_INDEX)
        group.each do |worker|
          worker.rpc.notify({ action: "conditional_fail", delay: 0.2, code: 99 })
        end

        failure = group.wait_for_failure

        expect(failure).to be_a(AsyncWorkers::WorkerFailure)
        expect(failure.worker_index).to eq(1)
        expect(failure.exit_status.exitstatus).to eq(99)
      end
    end

    it "workers without matching index continue running" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        # Only worker 2 should fail (pass fail_index in message)
        group[0].rpc.request({ action: "conditional_fail", fail_index: "999" })
        group[1].rpc.request({ action: "conditional_fail", fail_index: "999" })

        # Workers 0 and 1 should still be alive since no match
        expect(group[0].alive?).to be true
        expect(group[1].alive?).to be true

        group.stop
      end
    end
  end

  describe "per-worker communication" do
    it "sends individual requests to specific workers" do
      Async do |task|
        group = described_class.new(
          size:    3,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        # Each worker should return its own index
        responses = group.map.with_index do |worker, i|
          response = worker.rpc.request({ action: "env" })
          { index: i, worker_index: response.dig(:result, :worker_index) }
        end

        expect(responses[0][:worker_index]).to eq("0")
        expect(responses[1][:worker_index]).to eq("1")
        expect(responses[2][:worker_index]).to eq("2")

        group.stop
      end
    end

    it "handles per-worker notifications" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        notifications_0 = []
        notifications_1 = []

        group.start(task: task)

        group[0].rpc.on_notification { |n| notifications_0 << n }
        group[1].rpc.on_notification { |n| notifications_1 << n }

        # Send different notification counts to each worker
        group[0].rpc.request({ action: "notify_progress", count: 2 })
        group[1].rpc.request({ action: "notify_progress", count: 4 })

        sleep 0.6

        expect(notifications_0.size).to eq(2)
        expect(notifications_1.size).to eq(4)

        group.stop
      end
    end

    it "processes files in parallel across workers" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        group.start(task: task)

        files = ["a.txt", "b.txt"]

        results = Async do |inner|
          tasks = group.workers.zip(files).map do |worker, file|
            inner.async do
              worker.rpc.request({ action: "process_file", filename: file, duration: 0.1 })
            end
          end
          tasks.map(&:wait)
        end.wait

        filenames = results.map { |r| r.dig(:result, :filename) }
        worker_indices = results.map { |r| r.dig(:result, :worker_index) }

        expect(filenames).to contain_exactly("a.txt", "b.txt")
        expect(worker_indices).to contain_exactly("0", "1")

        group.stop
      end
    end
  end

  describe "per-worker stderr" do
    it "captures stderr from individual workers" do
      Async do |task|
        group = described_class.new(
          size:    2,
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        stderr_0 = []
        stderr_1 = []

        group.start(task: task)

        group[0].stderr.on_data { |line| stderr_0 << line }
        group[1].stderr.on_data { |line| stderr_1 << line }

        group[0].rpc.request({ action: "log", message: "from worker 0" })
        group[1].rpc.request({ action: "log", message: "from worker 1" })

        sleep 0.2

        expect(stderr_0.any? { |l| l.include?("from worker 0") }).to be true
        expect(stderr_1.any? { |l| l.include?("from worker 1") }).to be true

        group.stop
      end
    end
  end
end

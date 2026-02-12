# frozen_string_literal: true

require "async"
require_relative "../../lib/async_workers"

RSpec.describe AsyncWorkers::RpcChannel do
  let(:worker_path) { File.expand_path("./support/test_worker.rb", __dir__) }
  let(:command) { ["ruby", worker_path] }

  describe "request/response" do
    it "sends simple request and receives response" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "echo", data: "hello" })
        expect(response[:result]).to eq("hello")

        process.stop
      end
    end

    it "handles multiple sequential requests" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        r1 = process.rpc.request({ action: "add", a: 1, b: 2 })
        r2 = process.rpc.request({ action: "add", a: 3, b: 4 })
        r3 = process.rpc.request({ action: "echo", data: "test" })

        expect(r1[:result]).to eq(3)
        expect(r2[:result]).to eq(7)
        expect(r3[:result]).to eq("test")

        process.stop
      end
    end

    it "handles concurrent requests with correct correlation" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        results = Async do |inner|
          tasks = 3.times.map do |i|
            inner.async do
              process.rpc.request({ action: "add", a: i, b: 100 })
            end
          end
          tasks.map(&:wait)
        end.wait

        expect(results.map { |r| r[:result] }).to contain_exactly(100, 101, 102)

        process.stop
      end
    end

    it "raises TimeoutError when request times out" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        expect {
          process.rpc.request({ action: "slow", seconds: 10 }, timeout: 0.5)
        }.to raise_error(Async::TimeoutError)

        process.kill
      end
    end

    it "succeeds when request completes within timeout" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "slow", seconds: 0.1 }, timeout: 5)
        expect(response[:result]).to eq("slow_done")

        process.stop
      end
    end

    it "handles error responses" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.request({ action: "error", code: 42, message: "test error" })
        expect(response[:error][:code]).to eq(42)
        expect(response[:error][:message]).to eq("test error")

        process.stop
      end
    end
  end

  describe "inbound notifications" do
    it "receives notifications via callback" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        notifications = []
        process.start(task: task)
        process.rpc.on_notification { |n| notifications << n }

        process.rpc.request({ action: "notify_progress", count: 3 })

        # Give time for notifications
        sleep 0.5

        expect(notifications.size).to eq(3)
        expect(notifications.map { |n| n[:percent] }).to eq([33, 67, 100])

        process.stop
      end
    end

    it "receives notifications via iterator" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        collected = []
        consumer = task.async do
          process.rpc.notifications.each do |n|
            collected << n
            break if collected.size >= 3
          end
        end

        process.rpc.request({ action: "notify_progress", count: 3 })

        consumer.wait
        expect(collected.size).to eq(3)

        process.stop
      end
    end

    it "receives periodic heartbeat notifications" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        notifications = []
        process.start(task: task)
        process.rpc.on_notification { |n| notifications << n }

        process.rpc.request({ action: "start_heartbeat", count: 3, interval: 0.1 })

        # Wait for heartbeats
        sleep 0.5

        heartbeats = notifications.select { |n| n[:type] == "heartbeat" }
        expect(heartbeats.size).to eq(3)
        expect(heartbeats.map { |h| h[:seq] }).to eq([0, 1, 2])

        process.stop
      end
    end

    it "handles mixed requests and notifications" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        notifications = []
        process.start(task: task)
        process.rpc.on_notification { |n| notifications << n }

        # Start heartbeats
        process.rpc.request({ action: "start_heartbeat", count: 5, interval: 0.1 })

        # Send request while notifications are streaming
        response = process.rpc.request({ action: "add", a: 10, b: 20 })
        expect(response[:result]).to eq(30)

        # Wait for all heartbeats
        sleep 1.0

        expect(notifications.size).to eq(5)

        process.stop
      end
    end
  end

  describe "outbound notifications" do
    it "sends notification without id" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        stderr_lines = []
        process.stderr.on_data { |line| stderr_lines << line }
        process.start(task: task)

        # log_message logs whether message has id
        process.rpc.notify({ action: "log_message" })

        # Poll for worker to process and flush stderr
        20.times do
          break if stderr_lines.any? { |l| l.include?("type=notification") }
          sleep 0.1
        end

        expect(stderr_lines.any? { |l| l.include?("type=notification") }).to be true

        process.stop
      end
    end

    it "notification does not block" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        # Fire notification and immediately send request
        process.rpc.notify({ action: "log_message" })
        response = process.rpc.request({ action: "echo", data: "quick" })

        expect(response[:result]).to eq("quick")

        process.stop
      end
    end
  end

  describe "graceful shutdown" do
    it "sends shutdown and receives acknowledgment" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        response = process.rpc.shutdown(timeout: 5)
        expect(response[:status]).to eq("shutting_down")

        # Process should exit on its own after shutdown
        process.wait(timeout: 2)
        expect(process.status).to eq(:exited)
      end
    end

    it "returns nil on shutdown timeout" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        # Make worker hang first
        process.rpc.notify({ action: "hang" })
        sleep 0.1

        response = process.rpc.shutdown(timeout: 0.5)
        expect(response).to be_nil

        process.kill
      end
    end
  end

  describe "error conditions" do
    it "raises ChannelClosedError when sending on closed channel" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)
        process.kill
        sleep 0.2

        expect {
          process.rpc.request({ action: "echo", data: "test" })
        }.to raise_error(AsyncWorkers::ChannelClosedError)
      end
    end

    it "raises ChannelClosedError for pending request when channel closes" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)

        request_task = task.async do
          process.rpc.request({ action: "hang" })
        end

        sleep 0.1
        process.kill

        expect { request_task.wait }.to raise_error(AsyncWorkers::ChannelClosedError)
      end
    end

    it "tracks closed? state correctly" do
      Async do |task|
        process = AsyncWorkers::ManagedProcess.new(
          command: command,
          rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
        )

        process.start(task: task)
        expect(process.rpc.closed?).to be false

        process.stop
        sleep 0.1

        expect(process.rpc.closed?).to be true
      end
    end
  end
end

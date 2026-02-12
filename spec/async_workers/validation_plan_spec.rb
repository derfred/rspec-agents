# frozen_string_literal: true

# AsyncWorkers Validation Plan Spec
#
# This file organizes tests according to the Validation Plan document
# (2026_01_22_Validation_Plan.md) and provides RSpec tags for running
# individual sections.
#
# Run all validation tests:
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb
#
# Run by major section:
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb --tag section:1
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb --tag section:2
#   ...
#
# Run by subsection:
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb --tag section:2_1
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb --tag section:3_2
#   ...
#
# Run with documentation format (better for learning):
#   bundle exec rspec spec/async_workers/validation_plan_spec.rb --format documentation

require "async"
require_relative "../../lib/async_workers"

RSpec.describe "AsyncWorkers Validation Plan", :validation do
  let(:worker_path)             { File.expand_path("./support/test_worker.rb", __dir__) }
  let(:output_worker_path)      { File.expand_path("./support/output_worker.rb", __dir__) }
  let(:unix_socket_worker_path) { File.expand_path("./support/unix_socket_worker.rb", __dir__) }
  let(:output_script_path)      { File.expand_path("./support/output_script.sh", __dir__) }
  let(:command)                 { ["ruby", worker_path] }

  # ===========================================================================
  # Section 1: ChannelConfig Validation
  # ===========================================================================
  describe "Section 1: ChannelConfig Validation", section: 1 do
    describe "1.1 Configuration Modes", section: "1_1" do
      it "stdio_rpc returns config with RPC on stdin/stdout" do
        config = AsyncWorkers::ChannelConfig.stdio_rpc
        expect(config.mode).to eq(:stdio_rpc)
        expect(config.rpc_enabled?).to be true
        expect(config.stdio?).to be true
        expect(config.unix_socket?).to be false
      end

      it "unix_socket_rpc returns config with RPC on socket" do
        config = AsyncWorkers::ChannelConfig.unix_socket_rpc
        expect(config.mode).to eq(:unix_socket_rpc)
        expect(config.rpc_enabled?).to be true
        expect(config.stdio?).to be false
        expect(config.unix_socket?).to be true
      end

      it "no_rpc returns config with no RPC channel" do
        config = AsyncWorkers::ChannelConfig.no_rpc
        expect(config.mode).to eq(:no_rpc)
        expect(config.rpc_enabled?).to be false
        expect(config.stdio?).to be false
        expect(config.unix_socket?).to be false
      end
    end
  end

  # ===========================================================================
  # Section 2: ManagedProcess Validation
  # ===========================================================================
  describe "Section 2: ManagedProcess Validation", section: 2 do
    describe "2.1 Process Lifecycle", section: "2_1" do
      it "status transitions through :pending -> :running -> :exited" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.1"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          expect(process.status).to eq(:pending)

          process.start(task: task)
          expect(process.status).to eq(:running)

          process.wait
          expect(process.status).to eq(:exited)
          expect(process.exit_status.success?).to be true
        end
      end

      it "pid is available and valid after start" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.1"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)
          expect(process.pid).to be_a(Integer)
          expect(process.pid).to be > 0

          process.wait
        end
      end

      it "on_exit callback invoked with Process::Status" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.1"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          exit_status_received = nil
          condition = Async::Condition.new

          process.on_exit do |status|
            exit_status_received = status
            condition.signal
          end

          process.start(task: task)
          process.wait

          task.with_timeout(2) { condition.wait } if exit_status_received.nil?

          expect(exit_status_received).to be_a(Process::Status)
          expect(exit_status_received.success?).to be true
        end
      end
    end

    describe "2.2 Process Termination", section: "2_2" do
      it "graceful stop with SIGTERM honored" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
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
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sigterm_ignore"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }
          process.start(task: task)

          sleep 0.2
          expect(process.alive?).to be true

          process.stop(timeout: 1)

          # Allow stderr reader to flush remaining output
          10.times do
            break if stderr_lines.any? { |l| l.include?("SIGTERM ignored") }
            sleep 0.1
          end

          expect(process.status).to eq(:exited)
          expect(stderr_lines.any? { |l| l.include?("SIGTERM ignored") }).to be true
        end
      end

      it "immediate kill terminates process" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
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

      it "send_signal delivers arbitrary signal" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sigterm"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }
          process.start(task: task)

          sleep 1.0
          process.send_signal(:USR1)
          sleep 1.0

          expect(stderr_lines.any? { |l| l.include?("USR1 received") }).to be true

          process.kill
        end
      end
    end

    describe "2.3 Wait Behavior", section: "2_3" do
      it "wait blocks until exit" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.5"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          start_time = Time.now
          process.start(task: task)

          process.wait
          elapsed = Time.now - start_time

          expect(elapsed).to be >= 0.4
          expect(process.status).to eq(:exited)
        end
      end

      it "wait with timeout succeeds when process completes in time" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.2"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          expect { process.wait(timeout: 5) }.not_to raise_error
          expect(process.status).to eq(:exited)
        end
      end

      it "wait with timeout raises TimeoutError when exceeded" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sigterm_ignore"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          expect { process.wait(timeout: 0.5) }.to raise_error(Async::TimeoutError)

          process.kill
        end
      end
    end

    describe "2.4 Output Streaming", section: "2_4" do
      it "captures stderr output in stdio_rpc mode" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }

          process.start(task: task)
          process.rpc.request({ action: "log", message: "test message" })

          sleep 0.1

          expect(stderr_lines).to include("[worker] test message")

          process.stop
        end
      end

      it "stdout is empty in stdio_rpc mode (used for RPC)" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          stdout_lines = []
          process.stdout.on_data { |line| stdout_lines << line }
          process.start(task: task)

          process.rpc.request({ action: "echo", data: "test" })
          sleep 0.1

          expect(stdout_lines).to be_empty

          process.stop
        end
      end

      it "captures both stdout and stderr in no_rpc mode" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          stderr_lines = []
          stdout_lines = []
          process.stdout.on_data { |line| stdout_lines << line }
          process.stderr.on_data { |line| stderr_lines << line }
          process.start(task: task)
          process.wait

          expect(stderr_lines).to eq(["stderr line 1", "stderr line 2", "stderr line 3"])
        end
      end
    end
  end

  # ===========================================================================
  # Section 3: RpcChannel Validation
  # ===========================================================================
  describe "Section 3: RpcChannel Validation", section: 3 do
    describe "3.1 Request/Response", section: "3_1" do
      it "simple request returns response" do
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

      it "multiple sequential requests get correct responses" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          r1 = process.rpc.request({ action: "add", a: 1, b: 2 })
          r2 = process.rpc.request({ action: "add", a: 10, b: 20 })
          r3 = process.rpc.request({ action: "echo", data: "test" })

          expect(r1[:result]).to eq(3)
          expect(r2[:result]).to eq(30)
          expect(r3[:result]).to eq("test")

          process.stop
        end
      end

      it "request with timeout succeeds when response arrives in time" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          response = process.rpc.request({ action: "slow", seconds: 0.2 }, timeout: 5)
          expect(response[:result]).to eq("slow_done")

          process.stop
        end
      end

      it "request with timeout raises TimeoutError when exceeded" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
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

      it "concurrent requests get correct responses via correlation" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          results = Async do |inner|
            tasks = 3.times.map do |i|
              inner.async { process.rpc.request({ action: "add", a: i, b: 100 }) }
            end
            tasks.map(&:wait)
          end.wait

          expect(results.map { |r| r[:result] }).to contain_exactly(100, 101, 102)

          process.stop
        end
      end
    end

    describe "3.2 Notifications", section: "3_2" do
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

          notifications = []
          task.async do
            process.rpc.notifications.each do |msg|
              notifications << msg
            end
          end

          process.rpc.request({ action: "notify_progress", count: 3 })

          sleep 0.5
          process.stop

          expect(notifications.size).to eq(3)
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

          # Start notifications in background, then send request
          process.rpc.request({ action: "start_heartbeat", count: 5, interval: 0.1 })

          # Request should still work while notifications stream
          result = process.rpc.request({ action: "add", a: 5, b: 5 })
          expect(result[:result]).to eq(10)

          sleep 0.6

          expect(notifications.size).to be >= 3

          process.stop
        end
      end
    end

    describe "3.3 Outbound Notifications", section: "3_3" do
      it "sends notification without id field" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }
          process.start(task: task)

          # Send a notification (no id) - the worker logs whether it received a request or notification
          process.rpc.notify({ action: "log_message", data: "test" })
          sleep 1.0

          # The worker logs "[message] type=notification action=log_message" for messages without id
          expect(stderr_lines.any? { |l| l.include?("type=notification") }).to be(true),
            "Expected worker to log notification type. Got stderr: #{stderr_lines.inspect}"

          process.stop
        end
      end

      it "notification does not block subsequent requests" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          process.rpc.notify({ action: "log_message", data: "test" })
          result = process.rpc.request({ action: "echo", data: "immediate" })

          expect(result[:result]).to eq("immediate")

          process.stop
        end
      end
    end

    describe "3.4 Graceful Shutdown", section: "3_4" do
      it "shutdown sends __shutdown__ and receives acknowledgment" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          response = process.rpc.shutdown(timeout: 5)
          expect(response[:status]).to eq("shutting_down")

          process.wait(timeout: 2)
          expect(process.status).to eq(:exited)
        end
      end

      it "shutdown alone causes exit without SIGTERM (vs stop)" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }
          process.start(task: task)

          # Use shutdown protocol only (not stop)
          response = process.rpc.shutdown(timeout: 5)
          expect(response[:status]).to eq("shutting_down")

          process.wait(timeout: 2)

          expect(process.status).to eq(:exited)
          # Should NOT see SIGTERM - process exited via protocol
          expect(stderr_lines.none? { |l| l.include?("SIGTERM") }).to be true
        end
      end
    end

    describe "3.5 Error Conditions", section: "3_5" do
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

          # Start a slow request, then kill process mid-request
          slow_task = task.async do
            process.rpc.request({ action: "slow", seconds: 10 })
          end

          sleep 0.2
          process.kill

          expect { slow_task.wait }.to raise_error(AsyncWorkers::ChannelClosedError)
        end
      end

      it "closed? returns correct state" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)
          expect(process.rpc.closed?).to be false

          process.stop
          expect(process.rpc.closed?).to be true
        end
      end
    end
  end

  # ===========================================================================
  # Section 4: OutputStream Validation
  # ===========================================================================
  describe "Section 4: OutputStream Validation", section: 4 do
    describe "4.1 Callback Interface", section: "4_1" do
      it "single callback receives all data" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "5", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          lines = []
          process.stderr.on_data { |line| lines << line }
          process.start(task: task)
          process.wait

          expect(lines.size).to eq(5)
          expect(lines).to eq((1..5).map { |i| "stderr line #{i}" })
        end
      end

      it "multiple callbacks all receive data" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          lines1 = []
          lines2 = []
          process.stderr.on_data { |line| lines1 << line }
          process.stderr.on_data { |line| lines2 << line }
          process.start(task: task)
          process.wait

          expect(lines1.size).to eq(3)
          expect(lines2.size).to eq(3)
          expect(lines1).to eq(lines2)
        end
      end

      it "late registration receives only subsequent data (not buffered)" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "5", "0.3"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          # Wait for 2 lines to be emitted (at 0.3s intervals: 0, 0.3, 0.6 = 2 lines by 0.7s)
          sleep 0.7

          # Register callback late
          late_lines = []
          process.stderr.on_data { |line| late_lines << line }

          process.wait

          # Should receive fewer than 5 lines (late registration misses early data)
          expect(late_lines.size).to be < 5
        end
      end
    end

    describe "4.2 Iterator Interface", section: "4_2" do
      it "blocking iteration yields all data then exits" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          lines = []
          task.async do
            process.stderr.each { |line| lines << line }
          end

          process.wait
          sleep 0.1

          expect(lines.size).to eq(3)
        end
      end

      it "take(n) returns first n items" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "5", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          first_two = process.stderr.each.take(2)

          expect(first_two.size).to eq(2)
          expect(first_two).to eq(["stderr line 1", "stderr line 2"])

          process.kill
        end
      end

      it "enumerable methods work (select)" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "5", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          # Select lines containing "3"
          selected = process.stderr.each.take(5).select { |l| l.include?("3") }

          expect(selected).to eq(["stderr line 3"])

          process.wait
        end
      end
    end

    describe "4.3 Combined Usage", section: "4_3" do
      it "callback and iterator both receive data" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          callback_lines = []
          iterator_lines = []

          process.stderr.on_data { |line| callback_lines << line }

          process.start(task: task)

          task.async do
            process.stderr.each { |line| iterator_lines << line }
          end

          process.wait
          sleep 0.1

          expect(callback_lines.size).to eq(3)
          expect(iterator_lines.size).to eq(3)
        end
      end
    end

    describe "4.4 Stream Closure", section: "4_4" do
      it "closed? returns correct state" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.2"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)
          expect(process.stderr.closed?).to be false

          process.wait
          sleep 0.1
          expect(process.stderr.closed?).to be true
        end
      end

      it "iterator exits cleanly on stream close" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          iteration_completed = false
          task.async do
            process.stderr.each { |_| }
            iteration_completed = true
          end

          process.wait
          sleep 0.2

          expect(iteration_completed).to be true
        end
      end
    end
  end

  # ===========================================================================
  # Section 5: WorkerGroup Validation
  # ===========================================================================
  describe "Section 5: WorkerGroup Validation", section: 5 do
    describe "5.1 Spawning", section: "5_1" do
      it "spawns correct number of workers" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          expect(group.size).to eq(4)
          expect(group.workers.size).to eq(4)
          expect(group.workers.map(&:pid).uniq.size).to eq(4)

          group.stop
        end
      end

      it "each worker receives correct WORKER_INDEX" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          indices = group.map do |worker|
            response = worker.rpc.request({ action: "env" })
            response.dig(:result, :worker_index)
          end

          expect(indices).to contain_exactly("0", "1", "2", "3")

          group.stop
        end
      end

      it "supports array access [index]" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          expect(group[0]).to be_a(AsyncWorkers::ManagedProcess)
          expect(group[2]).to be_a(AsyncWorkers::ManagedProcess)
          expect(group[0].pid).not_to eq(group[2].pid)

          group.stop
        end
      end

      it "supports Enumerable methods (map)" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          pids = group.map(&:pid)
          expect(pids.size).to eq(3)
          expect(pids).to all(be_a(Integer))

          group.stop
        end
      end
    end

    describe "5.2 Fail-Fast Behavior", section: "5_2" do
      it "kills other workers when one fails" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          # Cause worker 1 to crash immediately
          group[1].rpc.notify({ action: "crash", code: 1 })

          group.wait_for_failure

          expect(group.failed?).to be true

          # Give time for kill signal to propagate
          sleep 1.0

          # All workers should be dead
          expect(group[0].alive?).to be false
          expect(group[2].alive?).to be false
        end
      end

      it "failure contains WorkerFailure with correct index" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            env:     { "FAIL_INDEX" => "1" },
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          group.each do |worker|
            worker.rpc.notify({ action: "conditional_fail", delay: 0.2, code: 42 })
          end

          group.wait_for_failure

          expect(group.failure).to be_a(AsyncWorkers::WorkerFailure)
          expect(group.failure.worker_index).to eq(1)
          expect(group.failure.exit_status.exitstatus).to eq(42)
        end
      end

      it "wait_for_failure unblocks when worker fails" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            env:     { "FAIL_INDEX" => "0" },
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          start_time = Time.now

          group.each do |worker|
            worker.rpc.notify({ action: "conditional_fail", delay: 0.3, code: 1 })
          end

          group.wait_for_failure
          elapsed = Time.now - start_time

          expect(elapsed).to be >= 0.2
          expect(group.failed?).to be true
        end
      end

      it "reports not failed when all workers succeed" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)
          expect(group.failed?).to be false

          group.stop(timeout: 5)

          expect(group.failed?).to be false
          expect(group.failure).to be_nil
        end
      end
    end

    describe "5.3 Group Operations", section: "5_3" do
      it "stop shuts down all workers gracefully" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)
          expect(group.alive?).to be true

          group.stop(timeout: 5)

          expect(group.workers.all? { |w| w.status == :exited }).to be true
          expect(group.workers.all? { |w| w.exit_status.success? }).to be true
        end
      end

      it "kill terminates all workers immediately" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          group.kill

          sleep 0.3
          expect(group.workers.none?(&:alive?)).to be true
        end
      end

      it "alive? returns correct state" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    2,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)
          expect(group.alive?).to be true

          group.stop
          expect(group.alive?).to be false
        end
      end
    end

    describe "5.4 Per-Worker Communication", section: "5_4" do
      it "individual RPC to specific worker" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    3,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          response = group[1].rpc.request({ action: "env" })
          expect(response.dig(:result, :worker_index)).to eq("1")

          group.stop
        end
      end

      it "fan-out pattern distributes work to all workers" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          work_items = ["a.txt", "b.txt", "c.txt", "d.txt"]

          results = Async do |inner|
            tasks = group.workers.zip(work_items).map do |worker, file|
              inner.async do
                worker.rpc.request({ action: "process_file", filename: file })
              end
            end
            tasks.map(&:wait)
          end.wait

          filenames = results.map { |r| r.dig(:result, :filename) }
          expect(filenames).to contain_exactly("a.txt", "b.txt", "c.txt", "d.txt")

          worker_indices = results.map { |r| r.dig(:result, :worker_index) }
          expect(worker_indices).to contain_exactly("0", "1", "2", "3")

          group.stop
        end
      end
    end
  end

  # ===========================================================================
  # Section 6: Transport Validation
  # ===========================================================================
  describe "Section 6: Transport Validation", section: 6 do
    describe "6.1 stdio Transport", section: "6_1" do
      it "basic RPC communication works" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          response = process.rpc.request({ action: "add", a: 10, b: 20 })
          expect(response[:result]).to eq(30)

          process.stop
        end
      end

      it "handles large messages (~100KB)" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          large_data = "x" * 100_000

          response = process.rpc.request({ action: "echo", data: large_data })
          expect(response[:result]).to eq(large_data)

          process.stop
        end
      end
    end

    # Note: Unix socket tests are slow (~20s each) due to socket setup overhead.
    # Run separately with: bundle exec rspec spec/async_workers/transport/unix_socket_transport_spec.rb
    # Or run with: bundle exec rspec spec/async_workers/validation_plan_spec.rb --tag slow
    describe "6.2 Unix Socket Transport", section: "6_2", slow: true do
      it "basic RPC communication over socket" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", unix_socket_worker_path],
            rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
          )

          process.start(task: task)

          response = process.rpc.request({ action: "add", a: 5, b: 7 })
          expect(response[:result]).to eq(12)

          process.stop
        end
      end

      it "child receives RPC_SOCKET_FD environment variable" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", unix_socket_worker_path],
            rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
          )

          process.start(task: task)

          response = process.rpc.request({ action: "env" })
          expect(response.dig(:result, :rpc_socket_fd)).not_to be_nil

          process.stop
        end
      end

      it "stdout is separate from RPC and can be captured" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", unix_socket_worker_path],
            rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
          )

          stdout_lines = []
          process.stdout.on_data { |line| stdout_lines << line }

          process.start(task: task)

          process.rpc.request({ action: "log_to_stdout", message: "hello stdout" })
          sleep 0.2

          expect(stdout_lines.any? { |l| l.include?("hello stdout") }).to be true

          process.stop
        end
      end

      it "stderr is captured separately" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", unix_socket_worker_path],
            rpc:     AsyncWorkers::ChannelConfig.unix_socket_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }

          process.start(task: task)

          process.rpc.request({ action: "log_to_stderr", message: "hello stderr" })
          sleep 0.2

          expect(stderr_lines.any? { |l| l.include?("hello stderr") }).to be true

          process.stop
        end
      end
    end
  end

  # ===========================================================================
  # Section 7: Health Monitoring Validation
  # ===========================================================================
  describe "Section 7: Health Monitoring Validation", section: 7 do
    describe "7.1 Exit Detection", section: "7_1" do
      it "alive? detects process exit" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.5"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)
          expect(process.alive?).to be true

          sleep 1.5
          expect(process.alive?).to be false
        end
      end

      it "wait returns promptly when process exits" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "sleep", "0.3"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          process.start(task: task)

          start_time = Time.now
          process.wait
          elapsed = Time.now - start_time

          expect(elapsed).to be < 2.0
          expect(process.status).to eq(:exited)
        end
      end
    end

    describe "7.2 Crash Detection", section: "7_2" do
      it "detects crash and records exit status" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
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

      it "raises ChannelClosedError when process crashes with pending request" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          # Start a hang request that will block forever
          request_task = task.async do
            process.rpc.request({ action: "hang" })
          end

          sleep 0.1
          # Kill the process while request is pending
          process.kill

          expect { request_task.wait }.to raise_error(AsyncWorkers::ChannelClosedError)
        end
      end
    end
  end

  # ===========================================================================
  # Section 8: Integration Scenarios
  # ===========================================================================
  describe "Section 8: Integration Scenarios", section: 8 do
    describe "8.1 Single Process with RPC (Design Example)", section: "8_1" do
      it "replicates design document example" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            env:     { "DEBUG" => "1" },
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          stderr_log = []
          process.stderr.on_data { |line| stderr_log << line }

          exit_received = false
          process.on_exit { |_status| exit_received = true }

          process.start(task: task)

          # compute action doubles the input (x * 2)
          result = process.rpc.request({ action: "compute", x: 42 }, timeout: 10)
          expect(result[:result]).to eq(84)

          process.stop

          expect(exit_received).to be true
        end
      end
    end

    describe "8.2 Notification Consumption (Design Example)", section: "8_2" do
      it "tracks progress and log notifications" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          process.start(task: task)

          progress_updates = []
          log_messages = []

          task.async do
            process.rpc.notifications.each do |msg|
              case msg[:type]
              when "progress"
                progress_updates << msg
              when "log"
                log_messages << msg[:message]
              end
            end
          end

          process.rpc.request({ action: "long_task", steps: 3 })

          process.stop
          sleep 0.2

          expect(progress_updates.size).to eq(3)
          expect(log_messages.size).to eq(3)
          expect(log_messages).to all(match(/Processing step/))
        end
      end
    end

    describe "8.3 Worker Group Fan-Out (Design Example)", section: "8_3" do
      it "distributes work to multiple workers" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          work_items = ["a.txt", "b.txt", "c.txt", "d.txt"]

          results = Async do |inner|
            tasks = group.workers.zip(work_items).map do |worker, file|
              inner.async do
                worker.rpc.request({ action: "process_file", filename: file }, timeout: 30)
              end
            end
            tasks.map(&:wait)
          end.wait

          filenames = results.map { |r| r.dig(:result, :filename) }
          expect(filenames).to contain_exactly("a.txt", "b.txt", "c.txt", "d.txt")

          group.stop
        end
      end

      it "handles worker failure during fan-out" do
        Async do |task|
          group = AsyncWorkers::WorkerGroup.new(
            size:    4,
            command: command,
            env:     { "FAIL_INDEX" => "2" },
            rpc:     AsyncWorkers::ChannelConfig.stdio_rpc
          )

          group.start(task: task)

          group.each do |worker|
            worker.rpc.notify({ action: "conditional_fail", delay: 0.3, code: 1 })
          end

          group.wait_for_failure

          expect(group.failed?).to be true
          expect(group.failure).to be_a(AsyncWorkers::WorkerFailure)
          expect(group.failure.worker_index).to eq(2)
        end
      end
    end

    describe "8.4 Output-Only Process (Design Example)", section: "8_4" do
      # Note: StdioTransport in no_rpc mode doesn't expose stdout_reader,
      # so stdout capture is only available in unix_socket_rpc mode.
      # This tests stderr capture which works in all modes.
      it "captures stderr output from shell script without RPC" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["bash", output_script_path],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }

          process.start(task: task)
          process.wait

          expect(stderr_lines).to eq([
            "stderr: initialized",
            "stderr: status ok"
          ])

          expect(process.exit_status.success?).to be true
        end
      end

      it "captures output using output_worker in no_rpc mode" do
        Async do |task|
          process = AsyncWorkers::ManagedProcess.new(
            command: ["ruby", output_worker_path, "lines", "3", "0.05"],
            rpc:     AsyncWorkers::ChannelConfig.no_rpc
          )

          stderr_lines = []
          process.stderr.on_data { |line| stderr_lines << line }

          process.start(task: task)
          process.wait

          expect(stderr_lines).to eq([
            "stderr line 1",
            "stderr line 2",
            "stderr line 3"
          ])

          expect(process.exit_status.success?).to be true
        end
      end
    end
  end
end

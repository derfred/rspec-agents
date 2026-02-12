# Parallel Spec Runner Design Document

A parallel test execution system for rspec-agents that distributes individual spec examples across multiple worker processes, aggregates events, and provides both terminal and embedded controller modes.

## Related Documents

This design builds upon and integrates with several other system components:

| Document | Relationship |
|----------|--------------|
| [Process Management Library](2026_01_22_process_manager_design.md) | Provides `AsyncWorkers` for spawning and managing worker processes with RPC communication |
| [Observer System](2026_01_22_observer-system-design.md) | Defines the `EventBus` and event types that workers emit and the controller aggregates |
| [Simulator Framework](2026_01_14_simulator-design-doc.md) | Describes the test DSL and conversation simulation that runs inside each worker |
| [Terminal Runner](lib/rspec_agents/runners/terminal_runner.rb) | Reference implementation for in-process RSpec execution with event emission |

## 1. Overview

### 1.1 Goals

- **Parallel execution**: Run individual RSpec examples across N worker processes
- **Event streaming**: Forward all observer events from workers to a central controller
- **Dual mode operation**: Terminal CLI mode and embeddable controller for web integration
- **Transparent aggregation**: Buffer events per-example, display interleaved results

### 1.2 Non-Goals

- Work stealing or dynamic rebalancing
- Graceful shutdown protocol (SIGKILL is acceptable)
- WebSocket frontend implementation (API only)
- State isolation between specs (assume stateless tests)
- Distributed execution across machines

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      ParallelSpecController                              │
│  - Discovers and partitions examples                                     │
│  - Spawns WorkerGroup with N workers                                     │
│  - Receives event notifications via RPC                                  │
│  - Buffers events per example_id                                         │
│  - Emits to terminal or callback                                         │
│  - Tracks completion, aggregates results                                 │
└─────────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
    ┌─────────┐          ┌─────────┐          ┌─────────┐
    │Worker 0 │          │Worker 1 │          │Worker N │
    │         │          │         │          │         │
    │ .rpc ◄──┼──────────┼─► event │          │         │
    │ .stderr │          │ .stderr │          │ .stderr │
    └────┬────┘          └────┬────┘          └────┬────┘
         │                    │                    │
    ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
    │Headless │          │Headless │          │Headless │
    │ Runner  │          │ Runner  │          │ Runner  │
    │         │          │         │          │         │
    │EventBus │          │EventBus │          │EventBus │
    │    ↓    │          │    ↓    │          │    ↓    │
    │RpcNotify│          │RpcNotify│          │RpcNotify│
    └─────────┘          └─────────┘          └─────────┘
```

### 2.1 Layer Responsibilities

| Layer | Responsibility | Source |
|-------|----------------|--------|
| **ParallelSpecController** | Orchestrates workers, partitions work, aggregates events, provides API | This design |
| **WorkerGroup** | Manages worker processes via AsyncWorkers library | [Process Management](2026_01_22_process_manager_design.md#workergroup) |
| **ManagedProcess** | Individual worker lifecycle, RPC channel, output streams | [Process Management](2026_01_22_process_manager_design.md#managedprocess) |
| **HeadlessRunner** | In-worker RSpec execution, emits events via RPC | This design (variant of [TerminalRunner](lib/rspec_agents/runners/terminal_runner.rb)) |
| **RpcNotifyObserver** | Bridges EventBus to RPC channel (fire-and-forget) | This design |
| **EventBus** | Publish/subscribe for test events within each worker | [Observer System](2026_01_22_observer-system-design.md#6-eventbus-implementation) |

## 3. Work Distribution

### 3.1 Example-Level Splitting

Specs are split at the individual example level, not file level. This provides better load balancing when example execution times vary significantly (common with LLM-based tests).

```ruby
# Input: spec files or directories
["spec/booking_spec.rb", "spec/search_spec.rb"]

# Discovery: enumerate all examples
[
  "spec/booking_spec.rb[1:1]",    # BookingAgent > greeting > welcomes user
  "spec/booking_spec.rb[1:2]",    # BookingAgent > greeting > handles name
  "spec/booking_spec.rb[2:1]",    # BookingAgent > search > finds venues
  "spec/search_spec.rb[1:1]",     # SearchAgent > filters > by location
  ...
]

# Partition: round-robin across N workers
Worker 0: ["spec/booking_spec.rb[1:1]", "spec/booking_spec.rb[2:1]", ...]
Worker 1: ["spec/booking_spec.rb[1:2]", "spec/search_spec.rb[1:1]", ...]
```

### 3.2 Example Discovery

Uses RSpec's dry-run mode to enumerate examples without execution:

```ruby
class ExampleDiscovery
  def self.discover(paths)
    # RSpec --dry-run --format json outputs example metadata
    output = `bundle exec rspec #{paths.join(' ')} --dry-run --format json`
    data = JSON.parse(output)

    data["examples"].map do |ex|
      ExampleRef.new(
        id: ex["id"],                           # "spec/file.rb[1:2:3]"
        location: ex["location"],               # "spec/file.rb:42"
        full_description: ex["full_description"]
      )
    end
  end
end
```

### 3.3 Partitioning Strategy

Simple round-robin assignment. No timing-based optimization.

```ruby
class Partitioner
  def self.partition(examples, worker_count)
    # Returns Array of Arrays, one per worker
    examples.each_slice(worker_count).to_a.transpose.map(&:compact)
  end
end
```

## 4. Worker Process

Each worker is a child process spawned via the [AsyncWorkers](2026_01_22_process_manager_design.md) library. Workers communicate with the controller using JSON-RPC over stdio (see [Protocol Specification](2026_01_22_process_manager_design.md#protocol-specification)).

### 4.1 Headless Runner

A variant of [TerminalRunner](lib/rspec_agents/runners/terminal_runner.rb) that:
- Runs in a subprocess (spawned by AsyncWorkers)
- Receives example IDs via RPC request
- Emits all events as RPC notifications
- Returns summary when complete

```ruby
module RspecAgents
  module Runners
    class HeadlessRunner
      def initialize(rpc_channel:)
        @rpc = rpc_channel
        @event_bus = EventBus.new  # Local, not singleton

        # Bridge events to RPC notifications
        @event_bus.subscribe do |event|
          @rpc.notify({
            type: "event",
            event_type: event.class.name.split("::").last,
            payload: event.to_h
          })
        end
      end

      def run(example_ids)
        # Configure RSpec to run only specified examples
        RSpec.reset
        RSpec.configuration.reset

        # Inject our event bus into the test environment
        Thread.current[:rspec_agents_event_bus] = @event_bus

        # Run with filter
        options = RSpec::Core::ConfigurationOptions.new(example_ids)
        options.configure(RSpec.configuration)

        # Suppress default output
        null_output = StringIO.new
        RSpec.configuration.output_stream = null_output
        RSpec.configuration.formatters.clear

        # Register for lifecycle events
        register_lifecycle_listener

        runner = RSpec::Core::Runner.new(options)
        exit_code = runner.run($stderr, null_output)

        # Return summary
        {
          exit_code: exit_code,
          example_count: RSpec.world.example_count,
          failure_count: RSpec.world.filtered_examples.count { |e| e.exception }
        }
      end

      private

      def register_lifecycle_listener
        RSpec.configuration.reporter.register_listener(
          LifecycleEmitter.new(@event_bus),
          :example_started, :example_passed, :example_failed, :example_pending
        )
      end
    end
  end
end
```

### 4.2 Worker Entry Point

The worker process script that AsyncWorkers spawns. This follows the [Child Process Implementation Guide](2026_01_22_process_manager_design.md#child-process-implementation-guide) pattern:

```ruby
#!/usr/bin/env ruby
# bin/parallel_spec_worker

require "bundler/setup"
require "rspec_agents"
require "json"

# Detect transport mode (stdio or unix socket)
if ENV["RPC_SOCKET_FD"]
  socket = IO.for_fd(ENV["RPC_SOCKET_FD"].to_i)
  input = output = socket
else
  $stdout.sync = true
  input = $stdin
  output = $stdout
end

# Message loop
runner = nil
while (line = input.gets)
  msg = JSON.parse(line.chomp, symbolize_names: true)

  case msg[:action]
  when "__shutdown__"
    response = { reply_to: msg[:id], status: "shutting_down" }
    output.puts(response.to_json)
    output.flush
    break

  when "run_specs"
    runner ||= RspecAgents::Runners::HeadlessRunner.new(
      rpc_channel: RpcOutputAdapter.new(output)
    )

    result = runner.run(msg[:example_ids])

    response = { reply_to: msg[:id] }.merge(result)
    output.puts(response.to_json)
    output.flush
  end
end

# Simple adapter for fire-and-forget notifications
class RpcOutputAdapter
  def initialize(output)
    @output = output
    @mutex = Mutex.new
  end

  def notify(payload)
    @mutex.synchronize do
      @output.puts(payload.to_json)
      @output.flush
    end
  end
end
```

### 4.3 Event Flow

Events flow from the test execution through the worker's local EventBus to RPC notifications. This leverages the [Observer System](2026_01_22_observer-system-design.md) event types and the [RpcChannel](2026_01_22_process_manager_design.md#rpcchannel) notification mechanism:

```
Test Code (Simulator/Scripted conversation)
    │                           See: Simulator Framework Design
    ▼
Conversation#add_user_message   See: Observer System §3.4
    │
    ▼
EventBus#publish(UserMessage)   See: Observer System §6
    │
    ▼
RpcNotifyObserver (subscribed)  Bridges EventBus → RPC
    │
    ▼
RpcChannel#notify(...)          See: Process Management §RpcChannel
    │
    ▼
JSON over stdio                 See: Process Management §Protocol
    │
    ▼
ParallelSpecController#handle_notification
```

The event types forwarded include all those defined in [Observer System §5](2026_01_22_observer-system-design.md#5-event-types):
- `ExampleStarted`, `ExampleFinished` (lifecycle)
- `SimulationStarted`, `SimulationEnded` (simulation)
- `UserMessage`, `AgentResponse`, `TopicChanged` (turn-level)
- `InvariantEvaluated` (evaluation)
- `AgentError`, `JudgeError` (errors)

## 5. Controller

### 5.1 ParallelSpecController

Central orchestrator that works in both terminal and embedded modes. Uses [WorkerGroup](2026_01_22_process_manager_design.md#workergroup) for process management with fail-fast semantics.

```ruby
module RspecAgents
  class ParallelSpecController
    attr_reader :status, :results

    # @param worker_count [Integer] Number of parallel workers
    # @param fail_fast [Boolean] Stop all workers on first failure
    def initialize(worker_count:, fail_fast: false)
      @worker_count = worker_count
      @fail_fast = fail_fast
      @status = :idle  # :idle, :running, :completed, :failed, :cancelled
      @results = nil
      @event_callbacks = []
      @progress_callbacks = []

      # Per-example event buffers
      @example_buffers = Hash.new { |h, k| h[k] = [] }
      @completed_examples = []
      @mutex = Mutex.new
    end

    # Register callback for events (embedded mode)
    # @yield [event_type, payload] Called for each event
    def on_event(&block)
      @event_callbacks << block
    end

    # Register callback for progress updates
    # @yield [completed, total, failures] Called on example completion
    def on_progress(&block)
      @progress_callbacks << block
    end

    # Start a test run (async, returns immediately in embedded mode)
    # @param spec_paths [Array<String>] Paths to spec files or directories
    # @return [self]
    def start(spec_paths)
      raise "Already running" if @status == :running

      @status = :running
      @spec_paths = spec_paths

      @run_task = Async do |task|
        execute_run(task)
      end

      self
    end

    # Block until run completes
    # @return [RunResult]
    def wait
      @run_task&.wait
      @results
    end

    # Query current progress
    # @return [Hash] { completed:, total:, failures:, status: }
    def progress
      @mutex.synchronize do
        {
          completed: @completed_examples.size,
          total: @total_examples,
          failures: @failure_count,
          status: @status
        }
      end
    end

    # Cancel the current run
    def cancel
      return unless @status == :running

      @status = :cancelled
      @worker_group&.kill
    end

    private

    def execute_run(task)
      # Phase 1: Discover examples
      examples = ExampleDiscovery.discover(@spec_paths)
      @total_examples = examples.size

      # Phase 2: Partition across workers
      partitions = Partitioner.partition(examples, @worker_count)
      actual_worker_count = partitions.reject(&:empty?).size

      # Phase 3: Spawn workers
      @worker_group = AsyncWorkers::WorkerGroup.new(
        size: actual_worker_count,
        command: ["ruby", "bin/parallel_spec_worker"],
        env: {},
        rpc: AsyncWorkers::ChannelConfig.stdio_rpc
      )

      @worker_group.start(task: task)

      # Phase 4: Set up notification handlers
      @worker_group.each_with_index do |worker, i|
        worker.rpc.on_notification { |msg| handle_notification(i, msg) }
        worker.stderr.on_data { |line| handle_worker_stderr(i, line) }
      end

      # Phase 5: Dispatch work to workers
      responses = dispatch_work(task, partitions)

      # Phase 6: Collect results
      @results = aggregate_results(responses)
      @status = @results.success? ? :completed : :failed

      # Phase 7: Cleanup
      @worker_group.stop(timeout: 5)

      @results

    rescue AsyncWorkers::WorkerFailure => e
      @status = :failed
      @results = RunResult.new(
        success: false,
        error: "Worker #{e.worker_index} crashed: #{e.exit_status}"
      )
      @worker_group&.kill
      @results
    end

    def dispatch_work(task, partitions)
      # Send run_specs request to each worker in parallel
      tasks = @worker_group.workers.zip(partitions).map do |worker, examples|
        next if examples.nil? || examples.empty?

        task.async do
          worker.rpc.request({
            action: "run_specs",
            example_ids: examples.map(&:id)
          })
        end
      end

      tasks.compact.map(&:wait)
    end

    def handle_notification(worker_index, msg)
      return unless msg[:type] == "event"

      event_type = msg[:event_type]
      payload = msg[:payload]
      example_id = payload[:example_id]

      @mutex.synchronize do
        # Buffer event
        @example_buffers[example_id] << { type: event_type, payload: payload }

        # Check for example completion
        if ["ExamplePassed", "ExampleFailed", "ExamplePending"].include?(event_type)
          flush_example_buffer(example_id)
          @completed_examples << example_id
          @failure_count += 1 if event_type == "ExampleFailed"

          notify_progress

          # Fail-fast check
          if @fail_fast && event_type == "ExampleFailed"
            cancel
          end
        end
      end

      # Fire event callbacks (outside mutex)
      @event_callbacks.each { |cb| cb.call(event_type, payload) }
    end

    def flush_example_buffer(example_id)
      buffer = @example_buffers.delete(example_id)
      return unless buffer

      # Emit buffered events in order
      buffer.each do |event|
        emit_event(event[:type], event[:payload])
      end
    end

    def handle_worker_stderr(worker_index, line)
      # Forward worker stderr (useful for debugging)
      emit_event("WorkerLog", { worker_index: worker_index, line: line })
    end

    def notify_progress
      @progress_callbacks.each do |cb|
        cb.call(@completed_examples.size, @total_examples, @failure_count)
      end
    end

    def emit_event(type, payload)
      @event_callbacks.each { |cb| cb.call(type, payload) }
    end

    def aggregate_results(responses)
      total_examples = 0
      total_failures = 0

      responses.each do |r|
        total_examples += r[:example_count] || 0
        total_failures += r[:failure_count] || 0
      end

      RunResult.new(
        success: total_failures == 0,
        example_count: total_examples,
        failure_count: total_failures,
        completed_examples: @completed_examples
      )
    end
  end

  RunResult = Data.define(:success, :example_count, :failure_count, :completed_examples, :error) do
    def initialize(success:, example_count: 0, failure_count: 0, completed_examples: [], error: nil)
      super
    end

    def success?
      success
    end
  end
end
```

### 5.2 Event Buffering

Events are buffered per `example_id` and flushed when the example completes. This ensures that in terminal mode, events for each example are displayed together even though they may arrive interleaved from different workers.

```
Time    Worker 0                    Worker 1
─────────────────────────────────────────────────────
t0      ExampleStarted{id:A}
t1                                  ExampleStarted{id:B}
t2      UserMessage{id:A}
t3                                  UserMessage{id:B}
t4      AgentResponse{id:A}
t5      ExamplePassed{id:A}         ← flush buffer A, display A events
t6                                  AgentResponse{id:B}
t7                                  ExampleFailed{id:B}  ← flush buffer B

Terminal Output (after buffering):
  ▼ BookingAgent > greeting
    ○ welcomes user... ✓ 234ms
      User: "Hi there"
      Agent: "Welcome! How can I help?"
  ▼ SearchAgent > filters
    ○ by location... ✗ FAILED
      User: "Find venues in Berlin"
      Agent: "Here are some options..." (ERROR: ...)
```

## 6. Terminal Runner

### 6.1 ParallelTerminalRunner

CLI-focused runner that combines the controller with terminal output formatting. The output style follows the patterns established in [TerminalRunner](lib/rspec_agents/runners/terminal_runner.rb), displaying conversation events inline with test results.

```ruby
module RspecAgents
  module Runners
    class ParallelTerminalRunner
      COLORS = {
        red: "\e[31m", green: "\e[32m", yellow: "\e[33m",
        blue: "\e[34m", cyan: "\e[36m", dim: "\e[2m", reset: "\e[0m"
      }.freeze

      def initialize(worker_count:, fail_fast: false, output: $stdout, color: nil)
        @worker_count = worker_count
        @fail_fast = fail_fast
        @output = output
        @color = color.nil? ? output.respond_to?(:tty?) && output.tty? : color

        @current_group = nil
        @indent = 0
        @failures = []
      end

      # Run specs and return exit code
      # @param paths [Array<String>] Spec files or directories
      # @return [Integer] Exit code (0 = success, 1 = failures)
      def run(paths)
        controller = ParallelSpecController.new(
          worker_count: @worker_count,
          fail_fast: @fail_fast
        )

        # Wire up event display
        controller.on_event { |type, payload| handle_event(type, payload) }
        controller.on_progress { |c, t, f| update_progress(c, t, f) }

        # Print header
        print_header

        # Execute
        Async do
          controller.start(paths)
          controller.wait
        end

        result = controller.results

        # Print summary
        print_summary(result)
        print_failures if @failures.any?

        result.success? ? 0 : 1
      end

      private

      def handle_event(type, payload)
        case type
        when "ExampleStarted"
          print_example_started(payload)
        when "ExamplePassed"
          print_example_passed(payload)
        when "ExampleFailed"
          print_example_failed(payload)
          @failures << payload
        when "ExamplePending"
          print_example_pending(payload)
        when "UserMessage"
          print_user_message(payload)
        when "AgentResponse"
          print_agent_response(payload)
        when "WorkerLog"
          print_worker_log(payload) if ENV["DEBUG"]
        end
      end

      def print_header
        @output.puts
        @output.puts "#{colorize("⚡", :cyan)} Parallel spec runner (#{@worker_count} workers)"
        @output.puts
      end

      def print_example_started(payload)
        desc = payload[:description] || payload[:full_description]
        @output.print "  #{colorize("○", :white)} #{desc}..."
        @output.flush
      end

      def print_example_passed(payload)
        duration = format_duration(payload[:duration])
        @output.puts " #{colorize("✓", :green)} #{colorize(duration, :dim)}"
      end

      def print_example_failed(payload)
        @output.puts " #{colorize("✗", :red)} FAILED"
        if payload[:message]
          payload[:message].to_s.lines.first(3).each do |line|
            @output.puts "    #{colorize(line.chomp, :red)}"
          end
        end
      end

      def print_example_pending(payload)
        message = payload[:message] ? " (#{payload[:message]})" : ""
        @output.puts " #{colorize("⏸", :yellow)} pending#{message}"
      end

      def print_user_message(payload)
        @output.puts "      #{colorize("User:", :dim)} #{truncate(payload[:text], 60)}"
      end

      def print_agent_response(payload)
        @output.puts "      #{colorize("Agent:", :dim)} #{truncate(payload[:text], 60)}"
      end

      def print_worker_log(payload)
        @output.puts "    #{colorize("[worker-#{payload[:worker_index]}]", :dim)} #{payload[:line]}"
      end

      def update_progress(completed, total, failures)
        # Could implement a progress bar here
        # For now, progress is shown via example completion
      end

      def print_summary(result)
        @output.puts

        parts = []
        parts << "#{result.example_count} example#{"s" unless result.example_count == 1}"

        if result.failure_count > 0
          parts << colorize("#{result.failure_count} failure#{"s" unless result.failure_count == 1}", :red)
        else
          parts << colorize("0 failures", :green)
        end

        @output.puts parts.join(", ")
        @output.puts
      end

      def print_failures
        @output.puts colorize("Failures:", :red)
        @output.puts

        @failures.each_with_index do |f, i|
          @output.puts "  #{i + 1}) #{f[:full_description] || f[:description]}"
          @output.puts "     #{colorize(f[:message], :red)}" if f[:message]
          if f[:backtrace]&.any?
            f[:backtrace].first(3).each do |line|
              @output.puts "     #{colorize(line, :dim)}"
            end
          end
          @output.puts
        end
      end

      def colorize(text, color)
        return text unless @color
        "#{COLORS[color]}#{text}#{COLORS[:reset]}"
      end

      def format_duration(seconds)
        return "0ms" unless seconds
        seconds < 1 ? "#{(seconds * 1000).round}ms" : "#{seconds.round(2)}s"
      end

      def truncate(text, length)
        return "" unless text
        text.length > length ? "#{text[0, length - 3]}..." : text
      end
    end
  end
end
```

### 6.2 CLI Entry Point

```ruby
#!/usr/bin/env ruby
# bin/rspec-parallel

require "bundler/setup"
require "rspec_agents"
require "optparse"

options = {
  workers: 4,
  fail_fast: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: rspec-parallel [options] [files or directories]"

  opts.on("-w", "--workers COUNT", Integer, "Number of workers (default: 4)") do |w|
    options[:workers] = w
  end

  opts.on("--fail-fast", "Stop on first failure") do
    options[:fail_fast] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

paths = ARGV.empty? ? ["spec"] : ARGV

runner = RspecAgents::Runners::ParallelTerminalRunner.new(
  worker_count: options[:workers],
  fail_fast: options[:fail_fast]
)

exit runner.run(paths)
```

## 7. Embedded Mode API

### 7.1 Controller Usage

For embedding in a Falcon web server:

```ruby
class SpecRunnerEndpoint
  def initialize
    @controller = nil
    @mutex = Mutex.new
  end

  # POST /specs/run
  def start_run(spec_paths)
    @mutex.synchronize do
      raise "Run already in progress" if @controller&.status == :running

      @controller = RspecAgents::ParallelSpecController.new(
        worker_count: 4,
        fail_fast: false
      )

      @controller.on_event do |type, payload|
        broadcast_to_websockets({ event: type, data: payload })
      end

      @controller.on_progress do |completed, total, failures|
        broadcast_to_websockets({
          event: "progress",
          data: { completed: completed, total: total, failures: failures }
        })
      end

      Async do
        @controller.start(spec_paths)
      end

      { status: "started" }
    end
  end

  # GET /specs/progress
  def get_progress
    return { status: "idle" } unless @controller
    @controller.progress
  end

  # POST /specs/cancel
  def cancel_run
    return { status: "not_running" } unless @controller&.status == :running
    @controller.cancel
    { status: "cancelled" }
  end
end
```

### 7.2 WebSocket Event Stream

Events emitted to WebSocket clients:

```json
// Progress update
{
  "event": "progress",
  "data": { "completed": 5, "total": 20, "failures": 1 }
}

// Example lifecycle
{
  "event": "ExampleStarted",
  "data": {
    "example_id": "a3f2b1c9",
    "description": "welcomes user",
    "full_description": "BookingAgent greeting welcomes user",
    "location": "spec/booking_spec.rb:42"
  }
}

// Conversation events
{
  "event": "UserMessage",
  "data": {
    "example_id": "a3f2b1c9",
    "turn_number": 1,
    "text": "Hi, I need to book a venue",
    "time": "2026-01-23T10:30:00Z"
  }
}

{
  "event": "AgentResponse",
  "data": {
    "example_id": "a3f2b1c9",
    "turn_number": 1,
    "text": "Hello! I'd be happy to help you find a venue.",
    "tool_calls": [],
    "time": "2026-01-23T10:30:01Z"
  }
}

// Example result
{
  "event": "ExampleFailed",
  "data": {
    "example_id": "a3f2b1c9",
    "description": "welcomes user",
    "duration": 2.34,
    "message": "Expected friendly response but got...",
    "backtrace": ["spec/booking_spec.rb:45", ...]
  }
}
```

## 8. Communication Protocol

The protocol extends the [Message Format](2026_01_22_process_manager_design.md#message-format) defined in the Process Management design. Messages are newline-delimited JSON with `id`/`reply_to` correlation.

### 8.1 Controller → Worker Messages

**Run Specs Request:**
```json
{
  "id": "req-1",
  "action": "run_specs",
  "example_ids": [
    "spec/booking_spec.rb[1:1]",
    "spec/booking_spec.rb[1:2]",
    "spec/search_spec.rb[2:1]"
  ]
}
```

**Shutdown Request:**
```json
{
  "id": "shutdown-1",
  "action": "__shutdown__"
}
```

### 8.2 Worker → Controller Messages

**Event Notification (fire-and-forget):**
```json
{
  "type": "event",
  "event_type": "UserMessage",
  "payload": {
    "example_id": "a3f2b1c9",
    "turn_number": 1,
    "text": "Hi there",
    "source": "simulator",
    "time": "2026-01-23T10:30:00Z"
  }
}
```

**Run Complete Response:**
```json
{
  "reply_to": "req-1",
  "exit_code": 0,
  "example_count": 3,
  "failure_count": 0
}
```

**Shutdown Acknowledgment:**
```json
{
  "reply_to": "shutdown-1",
  "status": "shutting_down"
}
```

## 9. Failure Handling

### 9.1 Test Failures

Test failures are reported via `ExampleFailed` events (see [Observer System §5.2](2026_01_22_observer-system-design.md#52-event-definitions)) and aggregated in the final result. By default, execution continues. With `--fail-fast`, the controller cancels remaining work.

### 9.2 Worker Crashes

If a worker process exits unexpectedly (non-zero exit without completing), the [WorkerGroup fail-fast behavior](2026_01_22_process_manager_design.md#behavior) triggers:

1. `WorkerGroup` raises `WorkerFailure` exception (see [Error Handling](2026_01_22_process_manager_design.md#error-handling))
2. Controller catches exception, sets status to `:failed`
3. All remaining workers are killed immediately (SIGKILL)
4. Run result indicates failure with error message

```ruby
rescue AsyncWorkers::WorkerFailure => e
  @status = :failed
  @results = RunResult.new(
    success: false,
    error: "Worker #{e.worker_index} crashed: #{e.exit_status}"
  )
  @worker_group.kill
```

### 9.3 No Graceful Shutdown

Per requirements, graceful shutdown is not needed. Cancellation simply kills all workers:

```ruby
def cancel
  return unless @status == :running
  @status = :cancelled
  @worker_group.kill  # SIGKILL, no waiting
end
```

## 10. File Structure

```
lib/rspec_agents/
├── parallel/
│   ├── controller.rb           # ParallelSpecController
│   ├── example_discovery.rb    # Example enumeration via dry-run
│   ├── partitioner.rb          # Work distribution
│   ├── run_result.rb           # Result data structure
│   └── headless_runner.rb      # In-worker RSpec execution
├── runners/
│   ├── terminal_runner.rb      # Existing single-process runner
│   └── parallel_terminal_runner.rb  # CLI parallel runner
└── ...

bin/
├── rspec-parallel              # CLI entry point
└── parallel_spec_worker        # Worker process script
```

## 11. Implementation Phases

### Phase 1: Core Infrastructure
- [ ] `ExampleDiscovery` - enumerate examples via RSpec dry-run
- [ ] `Partitioner` - round-robin distribution
- [ ] `HeadlessRunner` - in-process RSpec with event emission
- [ ] Worker entry point script

### Phase 2: Controller
- [ ] `ParallelSpecController` - worker orchestration
- [ ] Event buffering and flushing
- [ ] Progress tracking
- [ ] Fail-fast support

### Phase 3: Terminal Mode
- [ ] `ParallelTerminalRunner` - CLI output formatting
- [ ] `bin/rspec-parallel` CLI entry point
- [ ] Color output and progress display

### Phase 4: Embedded Mode
- [ ] Event callbacks API
- [ ] Progress query API
- [ ] Cancellation support
- [ ] Integration tests with async context

## 12. Open Questions

1. **Example ID stability**: RSpec's `[1:2:3]` IDs are position-based and unstable. Should we use the [stable name-based IDs](2026_01_22_observer-system-design.md#4-stable-example-identifiers) from the observer system design for correlation, or accept RSpec's native IDs?

2. **Shared state**: The design assumes stateless tests. If tests share database state, how should setup/teardown be coordinated? (Marked as out of scope but worth noting)

3. **Resource limits**: Should there be a maximum examples-per-worker limit to prevent memory issues in long-running workers?

4. **Retry semantics**: If we later want to retry failed examples, should they go back to the same worker or any available worker?

---

## Appendix: Referenced Designs

| Design | Key Concepts Used |
|--------|-------------------|
| [Process Management](2026_01_22_process_manager_design.md) | `WorkerGroup`, `ManagedProcess`, `RpcChannel`, `OutputStream`, JSON-RPC protocol, fail-fast behavior |
| [Observer System](2026_01_22_observer-system-design.md) | `EventBus`, event types (`UserMessage`, `AgentResponse`, etc.), stable example IDs, `on_*` observer methods |
| [Simulator Framework](2026_01_14_simulator-design-doc.md) | Test DSL (`run_simulator`, `user.says`), conversation model, topics, criteria evaluation |

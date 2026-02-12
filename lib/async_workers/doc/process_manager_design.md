# Process Management Library Design Document

A Ruby library for managing child processes with structured communication, built on the `async` gem and Ruby fibers.

## Overview

This library provides a high-level abstraction for spawning and managing child processes with support for bidirectional JSON-based RPC communication, output streaming, health monitoring, and coordinated worker groups.

### Goals

- Spawn and manage child processes with full lifecycle control
- Support JSON-based RPC over multiple transport mechanisms
- Capture and stream process output (stdout/stderr)
- Detect process failures and crashes
- Coordinate multiple workers in a fan-out pattern
- Integrate cleanly with the `async` ecosystem

### Non-Goals

- Automatic restart/supervision (caller's responsibility)
- Inter-worker dependencies or communication
- Work distribution strategies (push/pull queues)
- Persistent message queues

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        WorkerGroup                               │
│  - Spawns N workers                                              │
│  - Fail-fast on any worker failure                               │
│  - Provides access to individual workers                         │
└─────────────────────────────────────┬───────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
   ┌────▼─────┐               ┌───────▼──┐               ┌─────────▼┐
   │ Worker 0 │               │ Worker 1 │               │ Worker N │
   │          │               │          │               │          │
   │ .rpc     │               │ .rpc     │               │ .rpc     │
   │ .stderr  │               │ .stderr  │               │ .stderr  │
   │ .stdout  │               │ .stdout  │               │ .stdout  │
   └────┬─────┘               └────┬─────┘               └────┬─────┘
        │                          │                          │
   ┌────▼─────┐               ┌────▼─────┐               ┌────▼─────┐
   │ Managed  │               │ Managed  │               │ Managed  │
   │ Process  │               │ Process  │               │ Process  │
   └────┬─────┘               └────┴─────┘               └────┬─────┘
        │                          │                          │
   ┌────▼─────┐               ┌────▼─────┐               ┌────▼─────┐
   │Transport │               │Transport │               │Transport │
   │(stdio/   │               │(stdio/   │               │(stdio/   │
   │ socket)  │               │ socket)  │               │ socket)  │
   └──────────┘               └──────────┘               └──────────┘
```

### Layer Responsibilities

| Layer | Responsibility |
|-------|----------------|
| **WorkerGroup** | Spawns multiple workers, fail-fast coordination, provides access to individual workers |
| **ManagedProcess** | Process lifecycle (spawn, stop, kill), health monitoring, output stream management |
| **RpcChannel** | Message correlation (request/response), notification handling, graceful shutdown protocol |
| **Transport** | Raw I/O over stdio or unix sockets |
| **OutputStream** | Unified callback and iterator interface for streaming data |

## Core Components

### ChannelConfig

Configures how RPC communication is established with the child process.

```ruby
# RPC over stdin/stdout, logs on stderr only
ChannelConfig.stdio_rpc

# RPC over unix domain socket, logs on stdout/stderr
ChannelConfig.unix_socket_rpc

# No RPC, just output capture
ChannelConfig.no_rpc
```

| Mode | RPC Channel | Log Channels | Child Receives |
|------|-------------|--------------|----------------|
| `stdio_rpc` | stdin/stdout | stderr | Messages on stdin |
| `unix_socket_rpc` | Unix domain socket | stdout, stderr | `RPC_SOCKET_FD` env var |
| `no_rpc` | None | stdout, stderr | Nothing special |

### ManagedProcess

Wraps a single child process with lifecycle management and communication.

```ruby
process = ManagedProcess.new(
  command: ['ruby', 'worker.rb', '--verbose'],
  env: { 'DEBUG' => '1', 'WORKER_ID' => '0' },
  rpc: ChannelConfig.stdio_rpc
)
```

#### Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `pid` | `Integer` | OS process ID |
| `status` | `Symbol` | `:pending`, `:running`, `:stopping`, `:exited` |
| `exit_status` | `Process::Status` | Exit status (nil until exited) |
| `rpc` | `RpcChannel` | RPC interface (nil if `no_rpc`) |
| `stderr` | `OutputStream` | Stderr line stream |
| `stdout` | `OutputStream` | Stdout line stream (empty if RPC uses stdio) |

#### Methods

| Method | Description |
|--------|-------------|
| `start(task:)` | Spawn process and begin monitoring |
| `stop(timeout: 5)` | Graceful shutdown: RPC shutdown → SIGTERM → SIGKILL |
| `kill` | Immediate SIGKILL |
| `send_signal(signal)` | Send arbitrary signal |
| `alive?` | Check if process is running |
| `wait` | Block (yield fiber) until process exits |
| `wait(timeout:)` | Block until exit or timeout (raises `Async::TimeoutError`) |
| `on_exit { \|status\| }` | Register exit callback |

### RpcChannel

Handles JSON message framing, request/response correlation, and notifications.

#### Methods

| Method | Description |
|--------|-------------|
| `request(payload, timeout: nil)` | Send request, wait for response |
| `notify(payload)` | Send fire-and-forget message |
| `shutdown(timeout: 5)` | Request graceful shutdown via protocol |
| `notifications` | `OutputStream` of incoming notifications |
| `on_notification { \|msg\| }` | Callback for notifications (convenience) |
| `closed?` | Check if channel is closed |

> **Note:** `rpc.shutdown` sends the shutdown message and awaits acknowledgment. It does not affect process state — use `process.stop` for full lifecycle management, which calls `rpc.shutdown` internally as the first step.

### OutputStream

Unified interface for consuming streaming data via callbacks or iteration.

```ruby
# Callback style - inline handling
stream.on_data { |item| puts item }

# Iterator style - blocking, use in dedicated task
stream.each { |item| puts item }

# Enumerable
stream.each.take(10)
```

Both styles can be used simultaneously on the same stream.

| Method | Description |
|--------|-------------|
| `on_data { \|item\| }` | Register callback (can register multiple) |
| `each { \|item\| }` | Blocking iterator, yields until stream closes |
| `closed?` | Check if stream is closed |

### WorkerGroup

Coordinates multiple identical workers in a fan-out pattern.

```ruby
group = WorkerGroup.new(
  size: 4,
  command: ['ruby', 'worker.rb'],
  env: { 'MODE' => 'batch' },
  rpc: ChannelConfig.stdio_rpc
)
```

#### Behavior

- All workers run the same command
- Each worker receives `WORKER_INDEX` env var (0, 1, 2, ...)
- If any worker exits with non-zero status, all other workers are killed immediately
- No automatic restart - caller handles recovery

#### Methods

| Method | Description |
|--------|-------------|
| `start(task:)` | Spawn all workers |
| `workers` | Returns array of all workers (also aliased as `to_a`) |
| `[index]` | Access worker by index |
| `each { \|worker\| }` | Iterate over workers |
| `size` | Number of workers |
| `stop(timeout: 5)` | Graceful shutdown of all workers (parallel) |
| `kill` | Immediate kill of all workers |
| `alive?` | True if all workers are running |
| `failed?` | True if any worker has failed |
| `failure` | The `WorkerFailure` exception (or nil) |
| `wait_for_failure` | Block until a worker fails |

`WorkerGroup` includes `Enumerable`, providing `map`, `select`, `each_with_index`, etc.

## Protocol Specification

### Message Format

Messages are newline-delimited JSON objects.

```
{"id":"uuid-1","action":"compute","x":42}\n
{"id":"uuid-2","reply_to":"uuid-1","result":84}\n
{"type":"progress","percent":50}\n
```

### Message Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | No | Message identifier for correlation |
| `reply_to` | No | References the `id` of the request being answered |
| `...` | - | Arbitrary payload fields |

### Message Types

| Has `id` | Has `reply_to` | Type | Description |
|----------|----------------|------|-------------|
| Yes | No | Request | Expects a response |
| No | No | Notification (outbound) | Fire-and-forget to child |
| - | Yes | Response | Reply to a request |
| No | No | Notification (inbound) | Unsolicited message from child |

### Graceful Shutdown Protocol

The parent sends a shutdown request:

```json
{"id":"shutdown-1","action":"__shutdown__"}
```

The child should:
1. Stop accepting new work
2. Complete or abort in-flight work
3. Send response: `{"reply_to":"shutdown-1","status":"shutting_down"}`
4. Exit cleanly

If the child doesn't respond within timeout, SIGTERM is sent, followed by SIGKILL.

## Transport Details

### stdio Transport

- Parent writes to child's stdin
- Parent reads from child's stdout
- stderr is separate, always captured as log output
- Simplest setup, no filesystem artifacts

### Unix Socket Transport

- Parent creates socket pair before spawning using `socketpair()`
- Both ends created atomically — no race conditions
- Child inherits one end via file descriptor
- Child receives `RPC_SOCKET_FD` environment variable
- Bidirectional on single socket
- stdout and stderr both available for logging

## Health Monitoring

The library uses two complementary mechanisms:

1. **Process status polling** - Periodic `Process.waitpid(pid, WNOHANG)` to detect exits
2. **File descriptor closure** - EOF on transport streams indicates process termination

No heartbeat protocol is required. The polling interval is 500ms by default.

When an exit is detected, an internal `Async::Condition` is signaled, waking any fibers blocked on `wait`.

## Error Handling

### ChannelClosedError

Raised when attempting to send on a closed RPC channel, or when a pending request's channel closes.

### WorkerFailure

Raised by `WorkerGroup` when any worker exits with non-zero status. Contains:
- `worker_index` - Which worker failed
- `exit_status` - The `Process::Status` object

### Timeout Handling

Timeouts are specified per-request only:

```ruby
process.rpc.request(payload, timeout: 30)  # raises Async::TimeoutError
```

## Usage Examples

### Single Process with RPC

```ruby
Async do |task|
  process = ManagedProcess.new(
    command: ['ruby', 'worker.rb'],
    env: { 'DEBUG' => '1' },
    rpc: ChannelConfig.stdio_rpc
  )
  
  process.stderr.on_data { |line| logger.info("[worker] #{line}") }
  process.on_exit { |status| logger.info("Worker exited: #{status}") }
  
  process.start(task: task)
  
  result = process.rpc.request({ action: 'compute', x: 42 }, timeout: 10)
  
  process.stop
end
```

### Consuming Notifications via Iterator

```ruby
Async do |task|
  process = ManagedProcess.new(
    command: ['ruby', 'worker.rb'],
    rpc: ChannelConfig.stdio_rpc
  )
  
  process.start(task: task)
  
  # Dedicated task for notifications
  task.async do
    process.rpc.notifications.each do |msg|
      case msg.payload[:type]
      when 'progress'
        update_progress_bar(msg.payload[:percent])
      when 'log'
        logger.info(msg.payload[:message])
      end
    end
  end
  
  # Dedicated task for stderr
  task.async do
    process.stderr.each { |line| logger.debug(line) }
  end
  
  # Main work
  process.rpc.request({ action: 'long_running_task' })
  
  process.stop
end
```

### Worker Group Fan-Out

```ruby
Async do |task|
  group = WorkerGroup.new(
    size: 4,
    command: ['ruby', 'worker.rb'],
    rpc: ChannelConfig.stdio_rpc
  )
  
  group.start(task: task)
  
  # Set up output handlers
  group.each_with_index do |worker, i|
    worker.stderr.on_data { |line| logger.info("[worker-#{i}] #{line}") }
    worker.rpc.on_notification { |msg| handle_notification(i, msg) }
  end
  
  # Fan-out work
  work_items = ['a.txt', 'b.txt', 'c.txt', 'd.txt']
  
  results = Async do |inner|
    tasks = group.workers.zip(work_items).map do |worker, file|
      inner.async do
        worker.rpc.request({ action: 'process', file: file }, timeout: 30)
      end
    end
    tasks.map(&:wait)
  end
  
  group.stop
  
rescue WorkerGroup::WorkerFailure => e
  logger.error("Worker #{e.worker_index} failed")
  # Group already killed remaining workers
end
```

### Output-Only Process (No RPC)

```ruby
Async do |task|
  process = ManagedProcess.new(
    command: ['./batch_job.sh', 'input.csv'],
    rpc: ChannelConfig.no_rpc
  )
  
  lines = []
  process.stdout.on_data { |line| lines << line }
  process.stderr.on_data { |line| logger.warn(line) }
  
  process.start(task: task)
  
  # Wait for completion (yields fiber, no polling)
  process.wait
  
  puts "Captured #{lines.size} output lines"
  puts "Exit status: #{process.exit_status}"
end
```

### Waiting with Timeout

```ruby
Async do |task|
  process = ManagedProcess.new(
    command: ['./slow_job.sh'],
    rpc: ChannelConfig.no_rpc
  )
  
  process.start(task: task)
  
  begin
    process.wait(timeout: 30)
    puts "Completed: #{process.exit_status}"
  rescue Async::TimeoutError
    logger.warn("Process timed out, killing")
    process.kill
  end
end
```

## Child Process Implementation Guide

Child processes must implement the protocol to communicate with the parent.

### Detecting Transport Mode

```ruby
if ENV['RPC_SOCKET_FD']
  # Unix socket mode
  socket = IO.for_fd(ENV['RPC_SOCKET_FD'].to_i)
  run(input: socket, output: socket)
else
  # stdio mode (default)
  $stdout.sync = true
  run(input: $stdin, output: $stdout)
end
```

### Message Handling Loop

```ruby
def run(input:, output:)
  running = true
  
  while running && (line = input.gets)
    msg = JSON.parse(line.chomp, symbolize_names: true)
    
    if msg[:action] == '__shutdown__'
      running = false
      send_response(output, msg[:id], { status: 'shutting_down' })
      next
    end
    
    result = process_message(msg)
    send_response(output, msg[:id], result) if msg[:id]
  end
end

def send_response(output, request_id, payload)
  response = payload.merge(reply_to: request_id)
  output.puts(response.to_json)
  output.flush
end

def send_notification(output, payload)
  output.puts(payload.to_json)
  output.flush
end
```

### Sending Progress Notifications

```ruby
def process_message(msg)
  case msg[:action]
  when 'long_task'
    msg[:items].each_with_index do |item, i|
      # Send progress notification (no id = notification)
      send_notification(@output, {
        type: 'progress',
        percent: ((i + 1) * 100.0 / msg[:items].size).round
      })
      
      process_item(item)
    end
    
    { status: 'complete' }
  end
end
```

## Dependencies

- `async` - Fiber-based concurrency
- Ruby stdlib: `open3`, `json`, `socket`

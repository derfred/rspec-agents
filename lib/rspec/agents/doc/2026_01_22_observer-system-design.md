# Observer System Design Document

## 1. Problem Domain & Requirements

### 1.1 Overview

The rspec-agents framework runs simulated and scripted conversations as RSpec tests. Currently, test execution is opaque - users only see results after completion. This document describes an observer system that provides **live visibility** into conversation execution, enabling:

1. **Real-time conversation viewing**: See user and agent messages as they're generated
2. **Test progress monitoring**: Track which tests are running, passing, failing
3. **Cross-run correlation**: Compare conversations across multiple test runs
4. **Debugging support**: Understand why tests fail with full context

### 1.2 Design Goals

1. **Decoupled architecture**: Observers are independent of test execution - adding/removing observers doesn't affect test behavior
2. **Unified event source**: Both simulated and scripted runners emit the same events through the same mechanism
3. **Non-intrusive**: Observer failures never cause test failures
4. **Extensible**: Easy to add new observer implementations (file, WebSocket, custom)
5. **Stable identifiers**: Tests can be correlated across runs even when file contents change

### 1.3 Non-Goals (This Document)

- Frontend implementation details (TUI, Web UI)
- Streaming token-by-token output (future enhancement)
- Distributed/parallel test coordination
- Historical data storage and querying

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        RSpec Process                            │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   EventBus (singleton)                    │  │
│  │  - subscribe(event_type, &handler)                        │  │
│  │  - publish(event)                                         │  │
│  │  - thread-safe, error-isolated                            │  │
│  └───────────────────────────────────────────────────────────┘  │
│           ▲                    ▲                    ▲           │
│           │                    │                    │           │
│  ┌────────┴───────┐  ┌────────┴───────┐  ┌────────┴────────┐   │
│  │  RSpec Hooks   │  │  Conversation  │  │  Runner/Judge   │   │
│  │  (lifecycle)   │  │  (messages)    │  │  (errors)       │   │
│  └────────────────┘  └────────────────┘  └─────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │          Observers            │
              │  ┌─────────┐  ┌────────────┐  │
              │  │  JSONL  │  │ WebSocket  │  │
              │  │  File   │  │  Server    │  │
              │  └─────────┘  └────────────┘  │
              └───────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │       Frontend Viewers        │
              │  ┌─────────┐  ┌────────────┐  │
              │  │   CLI   │  │  Web UI    │  │
              │  │  Viewer │  │  Browser   │  │
              │  └─────────┘  └────────────┘  │
              └───────────────────────────────┘
```

### 2.1 Key Architectural Decisions

**Why Conversation as the event source (not Runners)?**

Both `SimulatedRunner` and `ScriptedRunner` mutate `Conversation` to track messages and turns. By emitting events from `Conversation`, we get unified behavior without duplicating instrumentation in each runner.

**Why EventBus (not direct observer registration)?**

A central EventBus allows:
- Observers to subscribe before runners are created
- Multiple observers without runner knowledge
- Easy testing (subscribe, run, assert events)

---

## 3. RSpec Integration

### 3.1 RSpec Execution Model

Understanding RSpec's execution model is essential for proper integration:

```
RSpec.configure
       │
       ▼
  before(:suite)  ─────────────────────────────────────────┐
       │                                                   │
       ▼                                                   │
  ┌─ Example Group (describe/context) ──────────────────┐  │
  │    before(:all)                                     │  │
  │         │                                           │  │
  │    ┌─ Example (it block) ────────────────────────┐  │  │
  │    │    before(:each)                            │  │  │
  │    │         │                                   │  │  │
  │    │    Example execution                        │  │  │
  │    │    - run_simulator { ... }                  │  │  │
  │    │    - user.says / expect(agent)              │  │  │
  │    │         │                                   │  │  │
  │    │    after(:each)                             │  │  │
  │    └─────────────────────────────────────────────┘  │  │
  │         │                                           │  │
  │    after(:all)                                      │  │
  └─────────────────────────────────────────────────────┘  │
       │                                                   │
       ▼                                                   │
  after(:suite)  ──────────────────────────────────────────┘
```

### 3.2 RSpec Metadata Access

Each example and example group carries metadata we can use:

```ruby
example.metadata[:description]       # "retries on timeout"
example.metadata[:full_description]  # "BookingAgent error handling retries on timeout"
example.metadata[:file_path]         # "./spec/booking_spec.rb"
example.metadata[:line_number]       # 42
example.metadata[:location]          # "./spec/booking_spec.rb:42"
example.metadata[:scoped_id]         # "1:2:3" (positional, unstable)
example.metadata[:parent_example_group]  # Link to parent describe/context
```

### 3.3 RSpec Hooks for Lifecycle Events

```ruby
module RspecAgents
  module RSpecIntegration
    def self.install!(event_bus)
      RSpec.configure do |config|
        config.before(:suite) do
          event_bus.publish(Events::SuiteStarted.new(
            time: Time.now,
            seed: RSpec.configuration.seed
          ))
        end

        config.after(:suite) do |suite|
          event_bus.publish(Events::SuiteFinished.new(
            time: Time.now,
            example_count: RSpec.world.example_count,
            failure_count: RSpec.world.filtered_examples.count(&:exception)
          ))
        end

        config.around(:each) do |example|
          example_event = Events::ExampleStarted.from_rspec(example)
          event_bus.publish(example_event)

          # Store example_id for conversation events
          Thread.current[:rspec_agents_example_id] = example_event.id

          begin
            example.run
          ensure
            Thread.current[:rspec_agents_example_id] = nil

            event_bus.publish(Events::ExampleFinished.new(
              id: example_event.id,
              status: example.execution_result.status,
              duration_ms: (example.execution_result.run_time * 1000).round,
              exception: format_exception(example.exception)
            ))
          end
        end
      end
    end

    def self.format_exception(exception)
      return nil unless exception
      {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace&.first(10)
      }
    end
  end
end
```

### 3.4 Conversation Integration

The `Conversation` class emits events when state changes:

```ruby
class Conversation
  def initialize(event_bus: EventBus.instance)
    @event_bus = event_bus
    @example_id = Thread.current[:rspec_agents_example_id]
    @messages = []
    @turns = []
    # ...
  end

  def add_user_message(text, source: :unknown)
    message = Message.new(role: :user, content: text)
    @messages << message

    @event_bus.publish(Events::UserMessage.new(
      example_id: @example_id,
      turn_number: @turns.size + 1,
      text: text,
      source: source,  # :simulator or :script
      time: Time.now
    ))

    message
  end

  def add_agent_response(response)
    turn = Turn.new(
      user_message: @messages.last,
      agent_response: response,
      topic: @current_topic
    )
    @turns << turn

    @event_bus.publish(Events::AgentResponse.new(
      example_id: @example_id,
      turn_number: @turns.size,
      text: response.text,
      tool_calls: response.tool_calls.map(&:to_h),
      time: Time.now
    ))

    turn
  end

  def set_topic(topic_name, trigger: nil)
    previous = @current_topic
    @current_topic = topic_name

    @event_bus.publish(Events::TopicChanged.new(
      example_id: @example_id,
      turn_number: @turns.size,
      from_topic: previous,
      to_topic: topic_name,
      trigger: trigger  # :trigger_match, :judge_classification, :initial
    ))
  end
end
```

---

## 4. Stable Example Identifiers

### 4.1 Problem with RSpec's Default IDs

RSpec provides two ID formats, both unstable:

| Format | Example | Instability |
|--------|---------|-------------|
| Line-based | `./spec/file.rb:65` | Changes when lines shift |
| Index-based | `./spec/file.rb[1:3:1]` | Changes when examples reorder |

### 4.2 Name-Based Stable IDs

We build IDs from the description chain, which is stable as long as test names don't change:

```ruby
module RspecAgents
  class StableExampleId
    def self.for(example)
      new(example.metadata).to_s
    end

    def initialize(metadata)
      @metadata = metadata
    end

    # Human-readable full ID
    def to_s
      "#{file_path}::#{description_chain.join(' > ')}"
    end

    # Short hash for database keys, filenames
    def to_hash
      Digest::SHA256.hexdigest(to_s)[0, 12]
    end

    def file_path
      @metadata[:rerun_file_path] || @metadata[:file_path]
    end

    def description_chain
      chain = []
      meta = @metadata

      while meta
        desc = meta[:description]
        chain.unshift(desc) if desc && !desc.empty?
        meta = meta[:parent_example_group]
      end

      chain
    end
  end
end
```

### 4.3 Example ID in Events

Events carry both the readable path and short hash:

```ruby
Events::ExampleStarted = Data.define(:id, :file, :path, :location, :time) do
  def self.from_rspec(example)
    stable_id = StableExampleId.new(example.metadata)
    new(
      id: stable_id.to_hash,           # "a3f2b1c9d4e5" - for correlation
      file: stable_id.file_path,       # "./spec/booking_spec.rb"
      path: stable_id.description_chain, # ["BookingAgent", "errors", "retries"]
      location: example.location,       # "./spec/booking_spec.rb:42" - for navigation
      time: Time.now
    )
  end
end
```

### 4.4 Correlation Example

Same test across runs produces identical IDs:

```
Run 1: { id: "a3f2b1c9d4e5", path: ["BookingAgent", "handles timeout"] }
Run 2: { id: "a3f2b1c9d4e5", path: ["BookingAgent", "handles timeout"] }

# Even after adding a new test above it:
Run 3: { id: "a3f2b1c9d4e5", path: ["BookingAgent", "handles timeout"] }
```

---

## 5. Event Types

### 5.1 Event Hierarchy

```
Events
├── Suite Level
│   ├── SuiteStarted
│   └── SuiteFinished
├── Example Level
│   ├── ExampleStarted
│   └── ExampleFinished
├── Simulation Level
│   ├── SimulationStarted
│   └── SimulationEnded
├── Turn Level
│   ├── UserMessage (source field indicates :simulator or :script)
│   ├── AgentResponse
│   └── TopicChanged
├── Tool Call Level
│   ├── ToolCallStarted
│   └── ToolCallCompleted
├── Evaluation Level
│   └── InvariantEvaluated
└── Error Level
    ├── AgentError
    └── JudgeError
```

Note: `SimulationStarted`/`SimulationEnded` bracket `user.simulate` calls explicitly.
For scripted conversations, the mode is inferred from `UserMessage.source` (`:script`).
`ConversationEnded` was removed as redundant with `SimulationEnded` and example lifecycle events.

### 5.2 Event Definitions

```ruby
module RspecAgents
  module Events
    # Suite Level
    SuiteStarted = Data.define(:time, :seed)
    SuiteFinished = Data.define(:time, :example_count, :failure_count)

    # Example Level
    ExampleStarted = Data.define(:id, :file, :path, :location, :time)
    ExampleFinished = Data.define(:id, :status, :duration_ms, :exception)
    # status: :passed, :failed, :pending

    # Simulation Level
    SimulationStarted = Data.define(:example_id, :goal, :max_turns, :time)
    # goal: String - the simulation goal from user.simulate { goal "..." }
    # max_turns: Integer - maximum turns configured for simulation
    SimulationEnded = Data.define(:example_id, :turn_count, :termination_reason, :time)
    # termination_reason: :max_turns, :stop_condition, :goal_reached, :error

    # Turn Level
    UserMessage = Data.define(:example_id, :turn_number, :text, :source, :time)
    # source: :simulator, :script
    AgentResponse = Data.define(:example_id, :turn_number, :text, :pending_tool_calls, :metadata, :time)
    # pending_tool_calls: Array<Hash> - tools requested by agent, not yet executed
    # metadata: Hash - extensible data (tracing, custom fields)
    TopicChanged = Data.define(:example_id, :turn_number, :from_topic, :to_topic, :trigger)
    # trigger: :trigger_match, :judge_classification, :initial

    # Tool Call Level
    ToolCallStarted = Data.define(:example_id, :turn_number, :tool_call_id, :tool_name, :arguments, :time)
    # tool_call_id: String - correlates started/completed events
    ToolCallCompleted = Data.define(:example_id, :turn_number, :tool_call_id, :tool_name, :arguments, :result, :error, :metadata, :time)
    # result: String | nil - tool output on success
    # error: String | nil - error message on failure
    # metadata: Hash - timing, database records, custom data

    # Evaluation Level
    InvariantEvaluated = Data.define(
      :example_id, :topic, :invariant_type, :description, :passed, :message
    )
    # invariant_type: :quality, :pattern, :tool_call, :grounding, :custom

    # Error Level
    AgentError = Data.define(:example_id, :turn_number, :error_class, :message, :context)
    JudgeError = Data.define(:example_id, :operation, :error_class, :message)
  end
end
```

### 5.3 JSON Serialization

All events serialize to JSON for transport:

```ruby
module Events
  # Add to each event type
  def to_h
    members.zip(values).to_h.merge(event_type: self.class.name.split('::').last)
  end

  def to_json(*args)
    to_h.to_json(*args)
  end
end
```

Example output:
```json
{
  "event_type": "UserMessage",
  "example_id": "a3f2b1c9d4e5",
  "turn_number": 1,
  "text": "I want to book a venue for 50 people",
  "source": "simulator",
  "time": "2026-01-22T10:30:00Z"
}
```

---

## 6. EventBus Implementation

### 6.1 Core EventBus

```ruby
module RspecAgents
  class EventBus
    include Singleton

    def initialize
      @subscribers = Hash.new { |h, k| h[k] = [] }
      @global_subscribers = []
      @mutex = Mutex.new
    end

    # Subscribe to specific event types
    def subscribe(*event_types, &handler)
      @mutex.synchronize do
        if event_types.empty?
          @global_subscribers << handler
        else
          event_types.each { |type| @subscribers[type] << handler }
        end
      end
      self
    end

    # Publish an event to all relevant subscribers
    def publish(event)
      handlers = @mutex.synchronize do
        @global_subscribers + @subscribers[event.class]
      end

      handlers.each do |handler|
        handler.call(event)
      rescue => e
        # Log but never break test execution
        warn "[RspecAgents::EventBus] Observer error: #{e.class}: #{e.message}"
        warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n") if ENV['DEBUG']
      end
    end

    # Clear all subscriptions (for testing)
    def clear!
      @mutex.synchronize do
        @subscribers.clear
        @global_subscribers.clear
      end
    end

    # Subscribe an observer object (responds to event methods)
    def add_observer(observer)
      subscribe do |event|
        method_name = "on_#{underscore(event.class.name.split('::').last)}"
        observer.send(method_name, event) if observer.respond_to?(method_name)
      end
    end

    private

    def underscore(camel_case)
      camel_case.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    end
  end
end
```

### 6.2 Observer Base Class

```ruby
module RspecAgents
  module Observers
    class Base
      def initialize(event_bus: EventBus.instance)
        event_bus.add_observer(self)
      end

      # Override in subclasses - method names derived from event types
      def on_suite_started(event); end
      def on_suite_finished(event); end
      def on_example_started(event); end
      def on_example_finished(event); end
      def on_conversation_started(event); end
      def on_conversation_ended(event); end
      def on_user_message(event); end
      def on_agent_response(event); end
      def on_topic_changed(event); end
      def on_tool_call_started(event); end
      def on_tool_call_completed(event); end
      def on_invariant_evaluated(event); end
      def on_agent_error(event); end
      def on_judge_error(event); end
    end
  end
end
```

---

## 7. Observer Implementations

### 7.1 JSONL File Observer

Writes events to a newline-delimited JSON file for later replay/analysis:

```ruby
module RspecAgents
  module Observers
    class JsonlFileObserver < Base
      def initialize(path:, **options)
        @file = File.open(path, 'a')
        @file.sync = true  # Flush after each write for real-time tailing
        super(**options)
      end

      def on_suite_started(event)
        write(event)
      end

      def on_example_started(event)
        write(event)
      end

      def on_user_message(event)
        write(event)
      end

      def on_agent_response(event)
        write(event)
      end

      # ... etc for all events

      def on_suite_finished(event)
        write(event)
        @file.close
      end

      private

      def write(event)
        @file.puts(event.to_json)
      end
    end
  end
end
```

Usage:
```bash
# In one terminal
$ tail -f events.jsonl | jq -r 'select(.event_type == "UserMessage" or .event_type == "AgentResponse") | "\(.turn_number). \(.source // "agent"): \(.text)"'

# In another terminal
$ RSPEC_AGENTS_EVENTS=events.jsonl rspec spec/
```

### 7.2 WebSocket Observer (Future)

```ruby
module RspecAgents
  module Observers
    class WebSocketObserver < Base
      def initialize(port: 4567, **options)
        @server = WebSocketServer.new(port: port)
        @server.start_async
        super(**options)
      end

      def broadcast(event)
        @server.broadcast(event.to_json)
      end

      alias_method :on_suite_started, :broadcast
      alias_method :on_example_started, :broadcast
      alias_method :on_user_message, :broadcast
      alias_method :on_agent_response, :broadcast
      # ... etc
    end
  end
end
```

---

## 8. Configuration

### 8.1 Programmatic Configuration

```ruby
RspecAgents.configure do |config|
  # Enable event system
  config.enable_events = true

  # Add observers
  config.observers << Observers::JsonlFileObserver.new(path: 'events.jsonl')
  config.observers << Observers::WebSocketObserver.new(port: 4567)

  # Or use a factory
  config.add_observer(:jsonl, path: 'events.jsonl')
  config.add_observer(:websocket, port: 4567)
end
```

### 8.2 Environment Variable Configuration

```bash
# Enable JSONL output
RSPEC_AGENTS_EVENTS=events.jsonl rspec spec/

# Enable WebSocket server
RSPEC_AGENTS_EVENTS=ws://localhost:4567 rspec spec/

# Multiple outputs
RSPEC_AGENTS_EVENTS=events.jsonl,ws://localhost:4567 rspec spec/
```

### 8.3 RSpec Integration Installation

```ruby
# In spec/spec_helper.rb or automatically via RspecAgents.configure
RspecAgents::RSpecIntegration.install!(RspecAgents::EventBus.instance)
```

---

## 9. Error Handling

### 9.1 Principles

1. **Observer errors never fail tests**: Exceptions in observers are caught and logged
2. **Agent errors are captured and re-raised**: We emit an event but don't swallow the error
3. **Partial data is better than no data**: If serialization fails, log and continue

### 9.2 Error Event Emission

```ruby
# In runner
def get_agent_response(messages)
  response = @agent.chat(messages)
  # ... emit AgentResponse event
  response
rescue => e
  @event_bus.publish(Events::AgentError.new(
    example_id: @example_id,
    turn_number: @current_turn,
    error_class: e.class.name,
    message: e.message,
    context: { messages_count: messages.size }
  ))
  raise  # Re-raise so test fails appropriately
end
```

---

## 10. Data Flow Example

Complete flow for a simulated conversation test:

```
1. RSpec loads spec file
2. before(:suite) → SuiteStarted { time, seed }

3. RSpec starts example "BookingAgent > books venue"
4. around(:each) → ExampleStarted { id: "a3f2", path: [...], location: "spec/b.rb:10" }

5. Test calls user.simulate { goal "Book a venue" }
   → SimulationStarted { example_id: "a3f2", goal: "Book a venue", max_turns: 15 }

6. Runner creates Conversation

7. Runner generates user message via LLM
   → UserMessage { example_id: "a3f2", turn: 1, text: "Hi, I need a venue", source: :simulator }

8. Runner calls agent.chat(messages)
   → AgentResponse { example_id: "a3f2", turn: 1, text: "Let me search...", pending_tool_calls: [{name: "search_venues", ...}], metadata: {tracing: {...}} }

9. Runner executes tool calls
   → ToolCallStarted { example_id: "a3f2", turn: 1, tool_call_id: "tc_1", tool_name: "search_venues", arguments: {...} }
   → ToolCallCompleted { example_id: "a3f2", turn: 1, tool_call_id: "tc_1", tool_name: "search_venues", result: "Found 3 venues", metadata: {...} }

10. Runner classifies topic via trigger
    → TopicChanged { example_id: "a3f2", turn: 1, from: nil, to: :greeting, trigger: :initial }

11. [Turns 2-5 repeat steps 7-10]

12. Runner evaluates topic invariants on exit
    → InvariantEvaluated { example_id: "a3f2", topic: :greeting, type: :quality, passed: true }

13. Simulation ends
    → SimulationEnded { example_id: "a3f2", turn_count: 5, termination_reason: :stop_condition }

14. around(:each) completes
    → ExampleFinished { id: "a3f2", status: :passed, duration_ms: 4523 }

16. after(:suite)
    → SuiteFinished { time, example_count: 12, failure_count: 1 }
```

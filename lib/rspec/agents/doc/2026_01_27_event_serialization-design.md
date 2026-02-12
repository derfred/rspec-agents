# Event Serialization System Design Document

## 1. Problem Domain & Requirements

### 1.1 Overview

The rspec-agents framework emits events during test execution via the EventBus system (see `observer-system-design.md`). This document describes a serialization layer that:

- Captures events into structured data for rendering and analysis
- Supports extensible metadata (LLM tracing, custom user data)
- Enables file-based persistence for later viewing
- Works with both single-process and parallel test execution

### 1.2 Existing Infrastructure

- **14 event types** in `lib/rspec_agents/events.rb` using `Data.define`
- **EventBus** singleton with thread-safe pub/sub (supports multiple subscribers)

### 1.3 Design Goals

1. **Generic metadata**: Extensible structure for arbitrary nested data (tracing, custom fields)
2. **Single builder class**: Same `RunDataBuilder` used in single-process and parallel (controller) modes
3. **Canonical AgentResponse**: `AgentResponse` event is the authoritative source for tool calls
4. **Computed summaries**: Statistics calculated on-demand, not stored

### 1.4 Non-Goals

- Streaming output (JSONL real-time tailing)
- Backward compatibility with `lib/rspec/agents` format
- Streaming chunks for token-by-token display

---

## 2. Architecture Overview

### 2.1 Single Process Mode

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         RSpec Process                                    │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │ RSpec Hooks  │  │ Conversation │  │  LLM Adapter │                   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                   │
│         │                 │                 │                            │
│         └─────────────────┼─────────────────┘                            │
│                           ▼                                              │
│                    ┌──────────────┐                                      │
│                    │   EventBus   │                                      │
│                    └──────┬───────┘                                      │
│                           │                                              │
│                           ▼                                              │
│                    ┌──────────────┐                                      │
│                    │RunDataBuilder│                                      │
│                    └──────┬───────┘                                      │
│                           │                                              │
│                           ▼                                              │
│                    ┌──────────────┐                                      │
│                    │   RunData    │                                      │
│                    └──────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Parallel Mode

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Worker Processes                                  │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐          │
│  │    Worker 1     │  │    Worker 2     │  │    Worker 3     │          │
│  │                 │  │                 │  │                 │          │
│  │  EventBus ──────┼──┼─ EventBus ──────┼──┼─ EventBus ──────┼──┐       │
│  │  (local)        │  │  (local)        │  │  (local)        │  │       │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │       │
│                                                                  │       │
└──────────────────────────────────────────────────────────────────┼───────┘
                                                                   │
                         Events forwarded via IPC                  │
                                                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Controller Process                                │
│                                                                          │
│                         ┌──────────────┐                                 │
│                         │   EventBus   │  (receives forwarded events)    │
│                         └──────┬───────┘                                 │
│                                │                                         │
│                                ▼                                         │
│                         ┌──────────────┐                                 │
│                         │RunDataBuilder│  (same class as single mode)    │
│                         └──────┬───────┘                                 │
│                                │                                         │
│                                ▼                                         │
│                         ┌──────────────┐                                 │
│                         │   RunData    │                                 │
│                         └──────────────┘                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

The key design decision: workers forward serialized events via IPC, and the controller reconstructs them. This allows the same `RunDataBuilder` class to work identically in both modes—it just subscribes to whatever EventBus is available.

---

## 3. Metadata System

The `Metadata` class is implemented in `lib/rspec_agents/metadata.rb`. It provides:

- Dynamic attribute access (`metadata.field = value`)
- Hash-style access (`metadata[:key]`)
- Scoped assignment (`metadata.scope!(:tracing) { |t| t.latency = 123 }`)
- Nested scopes and deep access via `dig`

See the implementation for full API details.

---

## 4. Data Model

### 4.1 Entity Hierarchy

```
RunData
├── run_id: String
├── started_at: Time
├── finished_at: Time?
├── seed: Integer
├── examples: Hash<String, ExampleData>
└── summary(): SummaryStats (computed)

ExampleData
├── id: String (from RSpec example_id)
├── file: String
├── description: String
├── location: String ("file:line")
├── status: Symbol (:pending, :running, :passed, :failed)
├── started_at: Time
├── finished_at: Time?
├── duration_ms: Integer?
├── exception: ExceptionData?
├── conversation: ConversationData?
├── evaluations: Array<EvaluationData>
└── metadata: Metadata

ConversationData
├── started_at: Time
├── ended_at: Time?
├── turns: Array<TurnData>
├── final_topic: String?
└── metadata: Metadata

TurnData
├── number: Integer (1-indexed)
├── user_message: MessageData
├── agent_response: MessageData?
├── tool_calls: Array<ToolCallData>
├── topic: String?
└── metadata: Metadata

MessageData
├── role: Symbol (:user, :agent)
├── content: String
├── timestamp: Time
├── source: Symbol? (:simulator, :script — user messages only)
└── metadata: Metadata (includes tracing for agent responses)

ToolCallData
├── name: String
├── arguments: Hash
├── result: String?
├── error: String?
├── timestamp: Time
└── metadata: Metadata

EvaluationData
├── name: String
├── description: String
├── passed: Boolean
├── reasoning: String?
├── timestamp: Time
└── metadata: Metadata

ExceptionData
├── class_name: String
├── message: String
└── backtrace: Array<String> (first 10 lines)
```

### 4.2 Design Decisions

**Computed summaries**: `RunData#summary` returns statistics (pass/fail counts, total duration) calculated on-demand rather than stored. This avoids synchronization issues in parallel mode and ensures consistency.

**AgentResponse is canonical**: The `AgentResponse` event from the EventBus is the authoritative source for tool calls. Any interim `ToolCallCompleted` events are discarded when `AgentResponse` arrives—no merging occurs.

**Metadata at every level**: Each data class has a `Metadata` field. This supports different use cases:
- `MessageData.metadata`: LLM tracing (tokens, latency, model)
- `ToolCallData.metadata`: Database records, API timing
- `ExampleData.metadata`: Custom test metadata

---

## 5. Event Types

### 5.1 Tool Call Events

Tool calls are captured via `ToolCallCompleted` events:

| Event | Purpose | Key Fields |
|-------|---------|------------|
| `ToolCallCompleted` | Records completed tool execution | `tool_name`, `arguments`, `result`, `error`, `metadata` |

### 5.2 Modified Events

| Event | Change |
|-------|--------|
| `AgentResponse` | Added `metadata` field (Hash) for tracing data |
| `SuiteStarted` | Added `seed` field for RSpec seed |

### 5.3 Event Flow for a Turn

```
1. UserMessage         → User says something
2. ToolCallCompleted   → Tool execution completes (optional, may repeat)
3. AgentResponse       → Agent responds (canonical source for tool_calls)
4. [Next turn or ExamplePassed/ExampleFailed]
```

The `AgentResponse` event is the authoritative source for tool calls. `ToolCallCompleted` events may be used for real-time display but are replaced by `AgentResponse.tool_calls` in the final data.

---

## 6. RunDataBuilder

### 6.1 Responsibilities

The `RunDataBuilder` class:
- Subscribes to all relevant events on the EventBus
- Maintains internal state for in-progress turns
- Builds the `RunData` structure incrementally
- Is thread-safe (uses mutex for parallel event arrival)

### 6.2 State Management

The builder tracks state per example:

**ConversationData creation**: Triggered by `ExampleStarted`. Each example gets a `ConversationData` initialized when the example begins.

**Turn tracking**: The builder tracks "current turns" per example—turns that have received a `UserMessage` but haven't yet been finalized. A turn is finalized when:
- A new `UserMessage` arrives (starts next turn)
- `ExamplePassed` or `ExampleFailed` is received

### 6.3 Tool Call Handling

When `AgentResponse` arrives:
- The `tool_calls` field from the event is used directly
- Any interim `ToolCallCompleted` events are discarded (no merging)

---

## 7. Serialization

### 7.1 JSON Format

All data classes implement `to_h` and `self.from_h` for JSON serialization:
- Times serialize as ISO 8601 with milliseconds
- Symbols serialize as strings
- Nested structures recurse

### 7.2 File Operations

`JsonFile` provides simple read/write:

```ruby
JsonFile.write("tmp/rspec_agents/run.json", run_data)
run_data = JsonFile.read("tmp/rspec_agents/run.json")
```

---

## 8. Parallel Execution

### 8.1 Event Forwarding

In parallel mode:
1. Each worker has its own local EventBus
2. Workers serialize events and forward via IPC (mechanism depends on parallel runner)
3. Controller receives events and republishes to its EventBus
4. Controller's `RunDataBuilder` processes events identically to single-process mode

### 8.2 Design Rationale

By forwarding events rather than partial data structures:
- Workers don't need to know about serialization format
- Controller uses the same builder class
- Event ordering is preserved per example (though interleaved across examples)

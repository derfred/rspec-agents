# Framework Infrastructure and Integration

## 1. Overview

This document describes the supporting infrastructure for the chatbot testing framework: adapter interfaces, RSpec integration, aggregation and metrics, experiment comparison, and output formats.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         RSpec Test Suite                         │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Conversation Runner                         │
├─────────────────────────────────────────────────────────────────┤
│  - Orchestrates turn-by-turn conversation                        │
│  - Invokes Simulator for user messages (simulated mode)          │
│  - Uses explicit messages (scripted mode)                        │
│  - Sends messages to Agent, captures responses & tool calls      │
│  - Classifies topics (triggers first, then LLM fallback)         │
│  - Records soft evaluations (evaluate) without failing           │
│  - Enforces hard expectations (expect) with immediate failure    │
│  - Tracks topic transitions and validates graph                  │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────────┐
│   Simulator     │  │  Agent Adapter  │  │     Judge       │
│   (LLM)         │  │   (Pluggable)   │  │     (LLM)       │
├─────────────────┤  ├─────────────────┤  ├─────────────────┤
│ Generates user  │  │ Sends messages  │  │ Classifies topic│
│ messages based  │  │ to agent API,   │  │ Evaluates quality│
│ on goal/persona │  │ returns response│  │ Checks grounding │
│ and context     │  │ and tool calls  │  │ Assesses intent  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## 3. Adapter Interfaces

### 3.1 Agent Adapter

The agent adapter handles communication with the chatbot under test. Each test receives a fresh agent instance via factory method.

#### Interface Contract

| Method | Purpose |
|--------|---------|
| `.build(context)` | Factory returning configured agent instance |
| `#chat(messages, on_tool_call: nil)` | Send conversation, receive `AgentResponse`, optionally signal tool calls |
| `#around(&block)` | Wrap test execution for isolation (optional) |
| `#metadata` | Return agent metadata for reporting (optional) |

#### Data Structures

**AgentResponse**:
- `text`: Agent's reply
- `tool_calls`: Array of ToolCall objects
- `metadata`: Optional (latency, model version, request IDs)

**ToolCall**:
- `name`: Tool identifier
- `arguments`: Hash of parameters
- `result`: Tool execution result
- `metadata`: Optional

**Test Context** (passed to `.build()`):
- Test name, file, line number, RSpec tags

#### Example Implementation

```ruby
class MyHttpAgent < RSpecAgents::Agents::Base
  def self.build(context = {})
    new(
      base_url: ENV["AGENT_URL"],
      api_key: ENV["AGENT_API_KEY"],
      context: context
    )
  end

  def around(&block)
    ActiveRecord::Base.transaction do
      block.call
      raise ActiveRecord::Rollback
    end
  end

  def chat(messages, on_tool_call: nil)
    response = call_agent_api(messages)

    on_tool_call&.call("name", arguments: {}, result: {})

    AgentResponse.new(
      text: response["content"],
      tool_calls: response["tool_calls"].map do |tc|
        ToolCall.new(
          name: tc["name"],
          arguments: tc["arguments"],
          result: tc["result"]
        )
      end,
      metadata: {
        latency_ms: response["timing"],
        request_id: response["id"]
      }
    )
  end
end
```

### 3.2 LLM Adapter

Provides completion interface for judge and simulator components.

#### Interface Contract

| Method | Purpose |
|--------|---------|
| `#complete(prompt, response_format:, max_tokens:)` | Generate completion |
| `#complete_with_schema(prompt, schema:, max_tokens:)` | Structured output (optional) |

#### Data Structures

**Response**:
- `text`: Raw completion text
- `parsed`: Parsed JSON (when `response_format: :json`)
- `metadata`: Model, latency, token counts

#### Example Implementation

```ruby
class MyLLM < RSpecAgents::LLM::Base
  def complete(prompt, response_format: :text, max_tokens: 1024)
    result = call_llm_api(prompt, max_tokens)
    
    parsed = response_format == :json ? JSON.parse(result.text) : nil
    
    Response.new(
      text: result.text,
      parsed: parsed,
      metadata: {
        model: result.model,
        latency_ms: result.timing,
        input_tokens: result.usage[:input],
        output_tokens: result.usage[:output]
      }
    )
  end
end
```

### 3.3 Configuration

#### Global

```ruby
RSpecAgents.configure do |config|
  # Agent: class or factory proc
  config.agent = MyHttpAgent
  config.agent = ->(context) { MyHttpAgent.new(url: "...", context: context) }
  
  # LLM for judge/simulator
  config.llm = MyLLM.new(model: "...")
end
```

#### Per-Test Overrides

Three syntaxes are supported for overriding agent configuration:

**1. Block with context argument (full control):**

```ruby
RSpec.describe "Booking Agent", type: :agent do
  agent { |context| MyHttpAgent.new(base_url: "http://staging.example.com", context: context) }

  context "experimental features" do
    agent { |context| MyHttpAgent.new(base_url: "http://experimental.example.com", context: context) }
  end
end
```

**2. super syntax (delegate to global adapter with additional context):**

When the global configuration specifies an agent class, test files can use `super(...)` to pass additional context while delegating agent construction to the global adapter:

```ruby
# In agents_helper.rb (global configuration)
RSpec::Agents.configure do |config|
  config.agent = FrogChatAgent  # Adapter class with .build(context) method
end

# In test file
RSpec.describe "Booking Agent", type: :agent do
  let(:shop) { create(:shop) }
  let(:person) { create(:person) }

  # Calls FrogChatAgent.build(context.merge(shop: shop, person: person))
  agent { super(shop: shop, person: person) }

  it "handles booking request" do
    user.says "I need a meeting room"
    # ...
  end
end
```

The `super()` syntax:
- Merges the provided keyword arguments with the framework-provided context (test name, file, line, tags)
- Calls the global adapter class's `.build(merged_context)` method
- Has access to RSpec `let` variables through normal scoping

**3. Class reference (uses .build with framework context only):**

```ruby
agent MyCustomAgent  # Calls MyCustomAgent.build(context)
```

---

## 4. RSpec Integration

### 4.1 Configuration Inheritance

```
┌─────────────────────────────────────────────────────────────────┐
│  RSpec.describe "Agent", type: :agent do                        │
│    criterion :friendly, "..."           # Inherited by children │
│    simulator do ... end                 # Inherited by children │
│    topic :greeting do ... end           # Shared topic          │
│                                                                 │
│    context "rushed users" do                                    │
│      criterion :handles_urgency, "..."  # Added to parent       │
│      simulator do ... end               # Merged with parent    │
│                                                                 │
│      it "handles urgent request" do                             │
│        expect_conversation_to do ... end                        │
│        user.simulate { goal "..." }                             │
│      end                                                        │
│    end                                                          │
│  end                                                            │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Inheritance Summary

| Setting | Behavior |
|---------|----------|
| `criterion` | Accumulated |
| `topic` | Accumulated |
| `simulator` | See test DSL document |

### 4.3 Execution Limits

```ruby
RSpec.describe "Agent", type: :agent do
  simulator do
    max_turns 15
    stop_when { |turn, conv| conv.has_tool_call?(:book_venue) }
  end
  
  context "quick interactions" do
    simulator do
      max_turns 5  # Overrides parent
    end
    
    it "handles quick lookup" do
      expect_conversation_to do
        use_topic :gathering_details, next: :results, max_turns: 3
        use_topic :results
      end
    end
  end
end
```

### 4.4 Aggregation Hooks

```ruby
RSpec.configure do |config|
  config.before(:suite) do
    RSpecAgents::Aggregator.start_experiment
  end
  
  config.after(:each, type: :agent) do |example|
    RSpecAgents::Aggregator.record_result(example)
  end
  
  config.after(:suite) do
    RSpecAgents::Aggregator.finalise_experiment
  end
end
```

### 4.5 Accessing Results

```ruby
experiment = RSpecAgents::Aggregator.current_experiment

experiment.completion_rate        # => 0.787
experiment.criteria_results       # => { friendly: 0.94, helpful: 0.89, ... }
experiment.scenario_results       # => [{ id: "...", passed: true, turns: 5 }, ...]
experiment.efficiency_metrics     # => { avg_turns: 5.4, avg_topics: 3.2 }
```

---

## 5. Assertion Modes in Aggregation

The framework distinguishes between soft evaluations (`evaluate`) and hard expectations (`expect`). This distinction flows through to aggregation and reporting.

### 5.1 How Modes Affect Metrics

| Metric | Soft Evaluations (`evaluate`) | Hard Expectations (`expect`) |
|--------|-------------------------------|------------------------------|
| **Completion Rate** | No effect | Failures reduce completion rate |
| **Criteria Performance** | Contributes pass/fail data | Contributes pass/fail data |
| **Scenario Pass/Fail** | No effect | Determines pass/fail |

A scenario can **pass** (contributing positively to completion rate) while having **failed soft evaluations** (captured in criteria performance). This allows quality measurement independent of flow correctness.

### 5.2 Result Recording

Each scenario records both evaluation outcomes and expectation results:

```ruby
ScenarioResult = Struct.new(
  :id,
  :name,
  :passed,              # Based on hard expectations only
  :turns,
  :topics_visited,
  :failure_type,        # :assertion, :error, :timeout, :max_turns, nil
  :failure_message,
  :evaluations,         # All soft evaluation results
  :expectations         # All hard expectation results
)

EvaluationResult = Struct.new(
  :turn_number,
  :assertion_type,      # :satisfy, :grounded_in, :match, etc.
  :criterion,           # Criterion name if applicable
  :passed,
  :details              # Judge reasoning, evidence
)
```

### 5.3 Example Scenario Output

```
Scenario: booking_with_modification

  Evaluations (soft):
    Turn 1:
      satisfy(:friendly)           ✓
      have_intent(:gather_req)     ✓
    Turn 2:
      be_grounded_in(:room_catalog) ✓
    Turn 3:
      satisfy(:acknowledges_change) ✗  "Response was curt"
      match(/3:00\s*pm/)           ✓
    Turn 4:
      be_grounded_in(:confirmation) ✓
      satisfy(:friendly)           ✓
      
  Expectations (hard):
    Turn 1: not call_tool(:book_room)     ✓
    Turn 2: call_tool(:check_availability) ✓
    Turn 3: call_tool(:check_availability) ✓
    Turn 4: call_tool(:book_room)          ✓
    
  Evaluation Summary: 7/8 passed (87.5%)
  Expectation Summary: 4/4 passed (100%)
  
  Result: PASSED
```

---

## 6. Aggregation Metrics

### 6.1 Completion Rate

Primary metric based on hard expectation pass/fail:

```
Scenario Set: venue_search (n=47)

  Completion Rate: 78.7% (37/47)
  
  By failure type:
    - passed: 37 (78.7%)
    - assertion: 5 (10.6%)      # Hard expectation failures
    - max_turns: 3 (6.4%)
    - error: 2 (4.3%)
```

### 6.2 Efficiency Metrics

```
Efficiency Metrics (n=47 scenarios)

  Turns to Completion:
    Mean: 5.4
    Median: 5
    Range: 3-12
    
  Topics Visited:
    Mean: 3.2
    Median: 3
    Range: 2-6
    
  Backtracking Rate: 12.8%
```

### 6.3 Criteria Performance

Aggregates all soft evaluations across scenarios and turns:

```
Criteria Performance (n=47 scenarios, 284 evaluations)

  Criterion          Evaluated    Passed    Rate
  ─────────────────────────────────────────────────
  :friendly          284          268       94.4%
  :helpful           284          253       89.1%
  :concise           189          156       82.5%
  :grounded_pricing  114          87        76.3%
  :acknowledges_change 47         41        87.2%
  
  Note: Criteria evaluated varies by scenario structure
```

### 6.4 Grounding Analysis

```
Grounding Analysis (n=47 scenarios)

  Claim Type         Evaluated    Grounded    Rate
  ─────────────────────────────────────────────────
  :venues            156          147         94.2%
  :pricing           89           70          78.7%
  :availability      62           44          71.0%
  
  Scenarios with highest ungrounded claim rates:
    - urgent_booking: 28.3% ungrounded
    - complex_requirements: 19.1% ungrounded
```

### 6.5 Combined View

```
Scenario Set Summary: venue_search (n=47)

  COMPLETION (hard expectations)
    Rate: 78.7% (37/47 passed)
    
  QUALITY (soft evaluations)
    Overall: 86.2% (1,847/2,143 evaluations passed)
    
    By criterion:
      :friendly          94.4%
      :helpful           89.1%
      :grounded_pricing  76.3%
      
  EFFICIENCY
    Avg turns: 5.4
    Avg topics: 3.2
```

---

## 7. Experiment Model

### 7.1 Experiment Identity

Each RSpec run constitutes an experiment with automatic metadata capture:

```ruby
Experiment = Struct.new(
  :id,              # UUID
  :timestamp,
  :name,            # Optional user-provided
  :tags,
  
  # Automatically captured
  :git_commit,
  :git_branch,
  :git_dirty,
  
  # Configuration fingerprints
  :config_hash,
  :criteria_hash,
  :topic_graph_hash
)
```

### 7.2 Configuration Fingerprinting

Fingerprints use canonical ordering for semantic equivalence:

```ruby
# Criteria: alphabetical by name
criteria_hash = Digest::SHA256.hexdigest(
  criteria_definitions.sort_by(&:name).map(&:to_fingerprint).join
)

# Topics: topological sort with alphabetical tie-breaking
sorted_topics = TopologicalSort.new(topics)
  .sort(tie_breaker: ->(a, b) { a.name <=> b.name })

topic_graph_hash = Digest::SHA256.hexdigest(
  sorted_topics.map { |t| [t.name, t.characteristic, t.successors.sort] }.to_json
)

# Overall
config_hash = Digest::SHA256.hexdigest(
  [criteria_hash, topic_graph_hash, simulator_config.to_json].join
)
```

### 7.3 Comparability Assessment

| Aspect | Rule |
|--------|------|
| Topic graph | Must be identical |
| Criteria | Identical preferred; changes flagged |
| Scenarios | Intersection compared |
| Scenario data | Expected to vary |
| Agent config | Expected to vary |
| LLM judge/simulator | Should be identical |

```
Comparability Assessment: Experiment A vs B

  ✓ Topic graph: identical
  ✓ Criteria: identical
  ⚠ Scenarios: 45 shared, 2 added, 1 removed
  ✓ Judge LLM: identical
  
  Comparison validity: HIGH
```

### 7.4 Acceptable Changes

**Criteria:**
- Adding: Flagged, compare shared only
- Removing: Flagged, excluded
- Modifying: Invalidates comparison for that criterion

**Scenarios:**
- Adding/removing: Compare intersection
- Modifying data: Expected variation

### 7.5 Stable Example IDs

Cross-experiment comparison requires stable identifiers for examples that survive code reorganization, line number changes, and example reordering. RSpec's native IDs (`spec/file.rb[1:2:3]`) are position-based and unstable.

**Stable ID Format**: `example:<12-char-hash>`

The hash is derived from the canonical path—the concatenated hierarchy of describe/context/it descriptions:

```
BookingAgent::venue search::returns results
```

For scenario-driven tests, the scenario's content-based identifier is appended:

```
BookingAgent::handles event@scenario_c3d4e5f6
```

This ensures:
- Same logical test = same ID across runs
- Different scenarios from `scenario_set` produce distinct IDs
- IDs survive file moves and example reordering

---

## 8. Experiment Comparison

### 8.1 Comparison Output

```
Experiment Comparison
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Baseline: exp_abc123 "Prompt v2.2" (2025-01-15)
Current:  exp_def456 "Prompt v2.3" (2025-01-16)

Scenarios compared: 45 (2 added, 1 removed)

─────────────────────────────────────────────────────────────────

Completion (Hard Expectations)
  Rate:           76.5% → 82.9%  (+6.4pp) ▲
  Avg Turns:      6.2 → 5.4      (-0.8)   ▲
  Avg Topics:     3.8 → 3.2      (-0.6)   ▲

─────────────────────────────────────────────────────────────────

Quality (Soft Evaluations)
  Overall:        81.2% → 86.8%  (+5.6pp) ▲

  By Criterion:
    Criterion              Baseline    Current    Delta
    ────────────────────────────────────────────────────
    :grounded_pricing      72.0%       89.0%      +17pp  ▲▲
    :helpful               88.0%       91.0%      +3pp   ▲
    :friendly              95.0%       94.0%      -1pp   ─
    :concise               81.0%       83.0%      +2pp   ▲

─────────────────────────────────────────────────────────────────

Scenario Changes
  Newly passing (2):
    - corporate_munich
    - urgent_booking
    
  Newly failing (1):
    - budget_conscious (was completing in 7 turns, now max_turns)
    
  Quality improved (5):
    - complex_requirements: 68% → 91% evaluation pass rate
    - large_conference: 72% → 88%
    
  Quality regressed (2):
    - budget_conscious: 85% → 71%
    - first_time_user: 90% → 78%

─────────────────────────────────────────────────────────────────
```

### 8.2 Quality Score

Completion rate (hard expectations) is the primary pass/fail metric. Evaluation pass rate (soft evaluations) provides quality signal:

```ruby
completion_rate = (passing_scenarios.count.to_f / total_scenarios.count * 100).round(1)
evaluation_rate = (passed_evaluations.count.to_f / total_evaluations.count * 100).round(1)
```

Quality gate decisions (thresholds, pass/fail) are operator responsibility—intentionally outside framework scope.

---

## 9. Variance Considerations

### 9.1 Sources

| Source | Impact | Mitigation |
|--------|--------|------------|
| Simulator LLM | Different messages each run | Consistent LLM version |
| Judge LLM | Evaluation variance | Consistent LLM version |
| Agent | Part of measurement | — |

### 9.2 Displaying Variance

Single experiment with multiple runs:

```
Completion Rate (3 runs of exp_abc123)

  Run 1: 78.7%
  Run 2: 76.5%
  Run 3: 80.2%
  
  Mean: 78.5%
  StdDev: 1.9pp

Evaluation Rate (3 runs)

  Run 1: 86.2%
  Run 2: 84.8%
  Run 3: 87.1%
  
  Mean: 86.0%
  StdDev: 1.2pp
```

Cross-experiment:

```
Comparison (with variance)

  Metric              Baseline           Current            Delta
  ─────────────────────────────────────────────────────────────────
  Completion Rate     76.5% ± 2.1pp      82.9% ± 1.8pp      +6.4pp
  Evaluation Rate     81.2% ± 1.5pp      86.8% ± 1.2pp      +5.6pp
  
  Note: Completion rate ranges do not overlap
```

### 9.3 Recommendations

1. Single runs acceptable for rapid iteration
2. Multiple runs recommended before deployment
3. Same LLM versions across compared experiments
4. Document variance when reporting

---

## 10. Output Formats

### 10.1 JSON

```json
{
  "experiment": {
    "id": "exp_def456",
    "timestamp": "2025-01-16T14:30:00Z",
    "name": "Prompt v2.3",
    "tags": ["grounding-focus"],
    "git_commit": "abc123def",
    "git_branch": "feature/grounding",
    "git_dirty": false,
    "config_hash": "sha256:...",
    "criteria_hash": "sha256:...",
    "topic_graph_hash": "sha256:..."
  },
  "summary": {
    "total_scenarios": 47,
    "passed": 37,
    "failed": 10,
    "completion_rate": 0.787,
    "evaluation_rate": 0.862,
    "avg_turns": 5.4,
    "avg_topics": 3.2
  },
  "criteria_results": {
    "friendly": { "evaluated": 284, "passed": 268, "rate": 0.944 },
    "helpful": { "evaluated": 284, "passed": 253, "rate": 0.891 },
    "grounded_pricing": { "evaluated": 114, "passed": 87, "rate": 0.763 }
  },
  "scenario_results": [
    {
      "id": "corporate_workshop_stuttgart",
      "name": "Corporate workshop in Stuttgart",
      "passed": true,
      "turns": 5,
      "topics_visited": ["greeting", "gathering_details", "presenting_results"],
      "failure_type": null,
      "failure_message": null,
      "evaluations": {
        "total": 12,
        "passed": 11,
        "rate": 0.917,
        "by_criterion": {
          "friendly": { "evaluated": 5, "passed": 5 },
          "helpful": { "evaluated": 5, "passed": 4 },
          "grounded_pricing": { "evaluated": 2, "passed": 2 }
        }
      },
      "expectations": {
        "total": 3,
        "passed": 3,
        "details": [
          { "type": "call_tool", "tool": "search_suppliers", "passed": true },
          { "type": "reached_topic", "topic": "presenting_results", "passed": true },
          { "type": "turn_count", "max": 10, "actual": 5, "passed": true }
        ]
      }
    }
  ]
}
```

### 10.2 Console

```
RSpec Agents: Experiment Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Experiment: exp_def456 "Prompt v2.3"
Timestamp:  2025-01-16 14:30:00 UTC
Git:        abc123def (feature/grounding)

─────────────────────────────────────────────────────────────────

Completion (Hard Expectations)
  Scenarios:        47 total, 37 passed, 10 failed
  Completion Rate:  78.7%
  Avg Turns:        5.4
  Avg Topics:       3.2

Quality (Soft Evaluations)
  Total Evaluations: 2,143
  Evaluation Rate:   86.2%

  By Criterion:
    :friendly          94.4%  (268/284)
    :helpful           89.1%  (253/284)
    :grounded_pricing  76.3%  (87/114)

─────────────────────────────────────────────────────────────────

Results saved to: results/exp_def456.json

To compare with baseline:
  rspec-agents compare exp_def456 --baseline exp_abc123
```

---

## 11. Data Source Interface

### 11.1 Current Support

JSON files for scenario loading:

```ruby
scenario_set "venues", from: "scenarios/venues.json"
```

### 11.2 Future Extensions

```ruby
# YAML
scenario_set "venues", from: "scenarios/venues.yml"

# Programmatic generation
scenario_set "venues", from: VenueScenarioGenerator.new(types: VENUE_TYPES)
```

The loader interface is designed for extension to additional data sources.
# Test Writing DSL and Scenario System

## 1. Overview

This document describes the domain-specific language for writing chatbot tests. The framework supports two modes of testing: simulated conversations where an LLM generates user messages, and scripted conversations with explicit message sequences. Both modes share a common vocabulary of assertions and can optionally track conversation flow through a topic graph.

The system consists of three LLM-powered components:

1. **Agent Under Test**: The chatbot being evaluated (external system)
2. **User Simulator**: An LLM that role-plays as a user with a specific goal and personality
3. **Judge**: An LLM that evaluates responses for quality, grounding, and conversation flow

---

## 2. Test Structure

A typical test file follows this structure:

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  # Shared configuration (inherited by all tests)
  criterion :friendly, "The agent's response should be friendly"
  
  simulator do
    role "Corporate event planner"
    max_turns 15
  end
  
  topic :greeting do
    characteristic "Initial contact phase"
  end
  
  # Test contexts group related tests
  context "standard flows" do
    it "handles venue search" do
      expect_conversation_to do
        use_topic :greeting, next: :gathering_details
      end
      
      user.simulate do
        goal "Find a venue for 50 attendees"
      end
    end
  end
end
```

### 2.1 Agent Configuration

Tests can override the global agent adapter by specifying additional context:

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  let(:shop) { create(:shop) }
  let(:person) { create(:person) }

  # Delegates to global adapter class with additional context
  agent { super(shop: shop, person: person) }

  it "handles venue search" do
    user.says "Find me a venue"
    # ...
  end
end
```

The `super()` syntax calls the globally configured adapter class's `.build` method with the merged context. This allows test files to provide test-specific data (like `shop` and `person`) without reimplementing the full agent construction logic.

For full control, use the block with context argument:

```ruby
agent { |context| MyAgent.build(context.merge(custom: "value")) }
```

---

## 3. Criteria

Criteria define quality standards the LLM judge uses to evaluate agent responses. Criteria accumulate through RSpec nesting—child contexts add to parent criteria.

### 3.1 String Description (Minimal)

Use when the description is self-explanatory:

```ruby
criterion :friendly, "The agent's response should be friendly and welcoming"
criterion :helpful, "The agent should move toward the user's goal"
```

### 3.2 Detailed with Examples

Use when examples help calibrate the LLM judge:

```ruby
criterion :grounded_pricing do
  description "Pricing information must be grounded in tool call results"
  
  good_example "The venue costs 500 EUR per day according to our search.",
    explanation: "Cites the source explicitly"
  
  bad_example "This venue is quite affordable at around 400-600 EUR.",
    explanation: "Vague range not matching any specific tool result"
  
  edge_case "Prices start at 500 EUR, though exact costs depend on your dates.",
    verdict: true,
    explanation: "Provides accurate base price with appropriate caveat"
end
```

### 3.3 Adhoc Criterions

Use when you need a one-off criterion without defining it at the describe/context level:

```ruby
it "handles form display" do
  user.says "I want to book a room"

  # Adhoc criterion - evaluated by LLM judge using the description
  expect(agent).to satisfy("Der Agent fragt nach Details oder zeigt das Formular an")

  # Can mix with named criteria
  evaluate(agent).to satisfy(:friendly)
  expect(agent).to satisfy("The agent acknowledges the request")
end
```

Adhoc criterions are useful for:
- Test-specific requirements that don't warrant a named criterion
- Exploratory testing with natural language descriptions
- Quick validation without ceremony

The description is passed directly to the LLM judge for evaluation.

### 3.4 Code-Based Evaluation

Use for deterministic evaluation without LLM calls:

```ruby
criterion :activated_workflow?, "The workflow agent is activated" do
  match do |conversation|
    conversation.called_tool?("start_workflow") > 0
  end
end

criterion :showed_form?, "The agent uses a form" do
  match_messages do |messages|
    messages.any? { |msg| msg.role == :agent && msg.content.include?("form:") }
  end
end
```

Code-based criteria must define either `match` (receives `Conversation`) or `match_messages` (receives array of `Message`), not both.

### 3.5 Inheritance

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  criterion :friendly, "..."
  criterion :helpful, "..."
  
  context "edge cases" do
    criterion :handles_errors, "Gracefully handles unexpected input"
    
    it "handles malformed request" do
      # Test has access to all 3 criteria
    end
  end
end
```

---

## 4. Assertion Modes: `evaluate` vs `expect`

The framework provides two assertion modes to distinguish between data collection and hard requirements.

### 4.1 Overview

| Mode | Syntax | On Failure | Use Case |
|------|--------|------------|----------|
| **Soft** | `evaluate(agent).to ...` | Records result, continues | Quality metrics |
| **Hard** | `expect(agent).to ...` | Fails test immediately | Flow requirements |

Soft evaluations treat criteria as data collection. A scenario can **pass** while having **failed evaluations**—this captures quality independently from flow correctness. Hard expectations enforce requirements that must be met.

### 4.2 Example

```ruby
it "handles booking flow" do
  user.says "Hi, I need a room"
  
  # Soft: records result, continues even if fails
  evaluate(agent).to satisfy(:friendly)
  evaluate(agent).to have_intent(:gather_requirements)
  
  user.says "Blue Room, tomorrow at 2pm"
  
  evaluate(agent).to satisfy(:helpful)
  evaluate(agent).to be_grounded_in(:room_catalog)
  
  # Hard: test fails if not met
  expect(agent).to call_tool(:check_availability)
  
  user.says "Yes, book it"
  
  evaluate(agent).to satisfy(:friendly)
  expect(agent).to call_tool(:book_room)
end
```

Both modes record results to metrics. See the Infrastructure document for aggregation details.

---

## 5. Topics

Topics represent distinct phases in a conversation. They enable the framework to track conversation flow and evaluate phase-specific invariants.

### 5.1 Topic Definition

```ruby
topic :gathering_details do
  characteristic <<~DESC
    The agent is collecting event requirements: dates, participants,
    location, budget, event type.
  DESC
  
  agent_intent "Collect sufficient information for a meaningful venue search"
  
  triggers do
    on_response_match /what.*looking for|tell me about.*event/i
  end
  
  # Soft: quality measurement
  evaluate_agent to_satisfy: [:friendly, :helpful]
  
  # Hard: flow requirements
  forbid_claims :venues, :pricing
end
```

| Component | Purpose |
|-----------|---------|
| `characteristic` | Description helping identify when conversation is in this topic |
| `agent_intent` | What the agent should accomplish during this phase |
| `triggers` | Deterministic rules for topic classification (avoiding LLM calls) |
| Invariants | Assertions evaluated when exiting this topic |

### 5.2 Triggers

Triggers enable deterministic topic classification:

```ruby
triggers do
  on_tool_call :search_suppliers
  on_tool_call :search_suppliers, with_params: { location: /stuttgart/i }
  on_response_match /would you like to proceed/i
  on_user_match /yes|confirm|book/i
  after_turns_in :gathering_details, count: 3
  on_condition ->(turn, conv) { conv.all_tool_calls.count >= 2 }
end
```

Current topic triggers are checked first, then successor topics. If both match, the conversation stays in the current topic. If no triggers match, the LLM judge classifies based on characteristics.

### 5.3 Shared vs Inline Topics

Topics defined at the RSpec level are shared templates without graph edges:

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  # Shared topic (no edges)
  topic :greeting do
    characteristic "Initial contact phase"
  end
  
  it "handles standard flow" do
    expect_conversation_to do
      # Wire shared topic with edges
      use_topic :greeting, next: :gathering_details
      
      # Inline topic with edges
      topic :gathering_details, next: :presenting_results do
        characteristic "Collecting requirements"
      end
    end
  end
end
```

### 5.4 Topic Invariants

Invariants are evaluated when the conversation exits a topic (simulated mode). Use `evaluate_agent` for quality metrics and `expect_agent` for requirements:

```ruby
topic :presenting_results do
  characteristic "Agent presenting venue search results"
  
  # Quality criteria (soft)
  evaluate_agent to_satisfy: [:friendly, :helpful]
  evaluate_agent to_match: /here are some options/i
  evaluate_grounding :venues, :pricing, from_tools: [:search_suppliers]
  
  # Flow requirements (hard)
  expect_agent not_to_match: /error|sorry/i
  expect_tool_call :search_suppliers
  forbid_tool_call :book_venue
  forbid_claims :availability
  
  # Custom blocks default to soft, use expect for hard
  evaluate "Response under 500 chars" do |turn, conversation|
    turn.agent_response.text.length <= 500
  end
end
```

All invariant types support both modes:

| Soft (evaluate) | Hard (expect) |
|-----------------|---------------|
| `evaluate_agent to_satisfy: [...]` | `expect_agent to_satisfy: [...]` |
| `evaluate_agent to_match: /.../` | `expect_agent to_match: /.../` |
| `evaluate_agent not_to_match: /.../` | `expect_agent not_to_match: /.../` |
| `evaluate_grounding :type, from_tools: [...]` | `expect_grounding :type, from_tools: [...]` |
| `evaluate_tool_call :name` | `expect_tool_call :name` |
| `evaluate "desc" do ... end` | `expect "desc" do ... end` |

The `forbid_*` variants are always hard expectations:

| Hard only |
|-----------|
| `forbid_claims :type` |
| `forbid_tool_call :name` |

---

## 6. Topic Graph

The `expect_conversation_to` block defines conversation flow as a directed graph.

### 6.1 The `next:` Parameter

| Format | Example | Meaning |
|--------|---------|---------|
| Single symbol | `next: :gathering_details` | One successor |
| Array | `next: [:option_a, :option_b]` | Multiple possible successors |
| Omitted | `next: []` or omit | Terminal topic |

### 6.2 Graph Definition

```ruby
expect_conversation_to do
  use_topic :greeting, next: :gathering_details
  use_topic :gathering_details, next: [:presenting_results, :clarification]
  use_topic :presenting_results, next: [:booking, :refine_search]
  use_topic :booking  # Terminal
  
  # Inline topics work identically
  topic :error_recovery, next: :gathering_details do
    characteristic "Recovering from invalid input"
    triggers { on_response_match /sorry.*understand/i }
  end
end
```

The first topic declaration becomes the initial topic.

### 6.3 Graph Validation

The framework validates:

1. **Referential integrity**: All topics in `next:` must be defined
2. **No self-loops**: `next: [:same_topic]` is disallowed
3. **Connectivity**: All topics must be reachable from initial topic
4. **No duplicates**: Each topic name appears once

---

## 7. Simulator Configuration

The simulator generates user messages based on role, personality, context, and rules.

### 7.1 Configuration Block

```ruby
simulator do
  role "Corporate event planner at Acme GmbH"
  
  personality do
    note "Professional demeanor"
    note "Values efficiency"
  end
  
  context do
    note "Works at Acme GmbH, based in Stuttgart"
    note "Typical budget: 30,000-50,000 EUR"
  end
  
  rule :should, "confirm understanding before searches"
  rule :should_not, "engage in small talk"
  
  max_turns 15
  
  stop_when do |turn, conversation|
    conversation.has_tool_call?(:book_venue)
  end
end
```

### 7.2 Inheritance

| Setting | Inheritance |
|---------|-------------|
| `role`, `personality`, `context` | String replaces; block notes merge |
| `rule` | Always accumulated |
| `max_turns`, `stop_when` | Replaced |
| `goal`, `template` | Test-level only |

```ruby
RSpec.describe "Agent", type: :agent do
  simulator do
    role "Corporate event planner"
    personality do
      note "Professional demeanor"
    end
    max_turns 15
  end
  
  context "rushed users" do
    simulator do
      personality "Impatient, tight deadline"  # Replaces parent
      max_turns 8                               # Overrides
      rule :should_not, "engage in small talk"  # Added
    end
  end
end
```

---

## 8. Test Modes

### 8.1 Simulated Conversations

An LLM generates user messages. Topic invariants are assessed on topic exit.

```ruby
it "handles venue search flow" do
  expect_conversation_to do
    use_topic :greeting, next: :gathering_details
    use_topic :gathering_details, next: :presenting_results
    use_topic :presenting_results
  end
  
  user.simulate do
    goal "Find a venue for a corporate workshop with 50 attendees"
    
    # Optional overrides
    personality "Extra cautious"
    rule :should, "ask for confirmation"
    
    # Topic-specific behavior
    during_topic :gathering_details do
      rule :should, "double-check every detail"
    end
  end
  
  # Post-simulation assertions (hard expectations)
  expect(conversation.turns.count).to be >= 3
  expect(conversation).to have_reached_topic(:presenting_results)
end
```

### 8.2 Scripted Conversations

Explicit user messages with per-turn assertions:

```ruby
it "handles booking with modification" do
  user.says "Hi, I need to book a meeting room"
  
  evaluate(agent).to satisfy(:friendly)
  evaluate(agent).to have_intent(:gather_requirements)
  expect(agent).not_to call_tool(:book_room)
  
  user.says "The Blue Room for tomorrow at 2pm, 10 people"
  
  expect(agent).to call_tool(:check_availability).with(
    room: "Blue Room",
    capacity: 10
  )
  evaluate(agent).to be_grounded_in(:room_catalog)
  
  user.says "Actually, make it 3pm instead"
  
  evaluate(agent).to satisfy(:acknowledges_change)
  expect(agent).to call_tool(:check_availability)
  evaluate(agent).to match(/3[:\s]?00\s*pm|15[:\s]?00/i)
  
  user.says "Yes, please book it"
  
  expect(agent).to call_tool(:book_room)
  evaluate(agent).to be_grounded_in(:booking_confirmation)
  evaluate(agent).to satisfy(:friendly)
  
  expect(conversation.turns.count).to eq(4)
end
```

### 8.3 Scripted with Topic Tracking

```ruby
it "progresses through expected topics" do
  expect_conversation_to do
    use_topic :greeting, next: :gathering_details
    use_topic :gathering_details, next: :confirming
  end
  
  user.says "Hi there!"
  
  expect(agent).to be_in_topic(:greeting)
  evaluate(agent).to satisfy(:friendly)
  
  user.says "I need a room for 20 people next Monday"
  
  expect(agent).to be_in_topic(:gathering_details)
  expect(conversation.topic_history).to eq([:greeting, :gathering_details])
end
```

---

## 9. Assertions

Both `evaluate` and `expect` support the same assertion types.

### 9.1 Quality Assertions

| Topic Invariant | Per-Turn (Soft) | Per-Turn (Hard) |
|-----------------|-----------------|-----------------|
| `evaluate_agent to_satisfy: [:friendly]` | `evaluate(agent).to satisfy(:friendly)` | `expect(agent).to satisfy(:friendly)` |

```ruby
# Named criterion (looked up from defined criteria)
evaluate(agent).to satisfy(:friendly)

# Adhoc criterion (evaluated directly by LLM judge)
expect(agent).to satisfy("Der Agent fragt nach Details oder zeigt das Formular an")
evaluate(agent).to satisfy("The response is concise and actionable")

# Custom lambda
evaluate(agent).to satisfy(->(turn) { turn.agent_response.text.length <= 500 })

# Named custom
evaluate(agent).to satisfy(:concise, ->(turn) { turn.agent_response.text.length <= 300 })
```

### 9.2 Pattern Matching

| Topic Invariant | Per-Turn (Soft) | Per-Turn (Hard) |
|-----------------|-----------------|-----------------|
| `evaluate_agent to_match: /pattern/i` | `evaluate(agent).to match(/pattern/i)` | `expect(agent).to match(/pattern/i)` |

```ruby
evaluate(agent).to match(/blue room/i, /confirmed/i)  # All must match
evaluate(agent).to match_any(/2:00\s*pm/i, /14:00/i)  # Any matches
```

### 9.3 Grounding Assertions

| Topic Invariant | Per-Turn (Soft) | Per-Turn (Hard) |
|-----------------|-----------------|-----------------|
| `evaluate_grounding :venues, from_tools: [:search]` | `evaluate(agent).to be_grounded_in(:venues)` | `expect(agent).to be_grounded_in(:venues)` |

Grounding assertions use an LLM judge that receives the agent's response alongside tool call results. The judge determines whether factual claims are supported by tool data.

### 9.4 Tool Call Assertions

| Topic Invariant | Per-Turn (Soft) | Per-Turn (Hard) |
|-----------------|-----------------|-----------------|
| `evaluate_tool_call :search_suppliers` | `evaluate(agent).to call_tool(:search_suppliers)` | `expect(agent).to call_tool(:search_suppliers)` |

```ruby
expect(agent).to call_tool(:book_room).with(
  room: "Blue Room",
  time: match(/14:00|2:00\s*pm/i)
)

expect(agent).to call_tool(:search_venues).with(
  location: "Stuttgart",
  capacity: be >= 50
)
```

### 9.5 Intent Assertions

| Topic Invariant | Per-Turn (Soft) | Per-Turn (Hard) |
|-----------------|-----------------|-----------------|
| `agent_intent "Gather requirements"` | `evaluate(agent).to have_intent(:gather_requirements)` | `expect(agent).to have_intent(:gather_requirements)` |

```ruby
evaluate(agent).to have_intent(:gather_requirements,
  described_as: "Ask clarifying questions about group size and date"
)
expect(agent).not_to have_intent(:upsell)
```

### 9.6 Topic Assertions (Scripted Only)

Topic assertions are typically hard expectations since they verify flow:

```ruby
expect(agent).to be_in_topic(:greeting)
expect(conversation.current_topic).to eq(:greeting)
expect(conversation.topic_history).to include(:gathering_details)
```

### 9.7 Custom Assertions

```ruby
# Topic invariant (soft)
evaluate "Response under 500 chars" do |turn, conversation|
  turn.agent_response.text.length <= 500
end

# Topic invariant (hard)
expect "Must have venue results" do |turn, conversation|
  turn.agent_response.tool_calls.any? { |tc| tc.name == :search_suppliers }
end

# Per-turn
evaluate(agent).to satisfy(->(turn) { turn.agent_response.text.length <= 500 })
expect(agent.response.length).to be <= 500
```

---

## 10. Scenario System

Scenarios are data-driven test instances that parameterize conversations while maintaining stable topic graph structure.

### 10.1 Scenario Schema

Minimal:

```json
{
  "id": "corporate_workshop_stuttgart",
  "name": "Corporate workshop in Stuttgart",
  "goal": "Find a venue for a 50-person corporate workshop in Stuttgart",
  "context": ["Works at Acme GmbH", "Budget around 30,000 EUR"],
  "personality": "Professional, values efficiency"
}
```

With verification data:

```json
{
  "id": "add_attendees_catering",
  "name": "Add attendees requiring catering",
  "goal": "Add 15 additional attendees to an existing booking",
  "context": ["Event already booked at Venue X"],
  "personality": "Detail-oriented planner",
  "verification": {
    "expected_services": ["catering", "dietary_accommodation"],
    "minimum_attendee_increase": 15
  }
}
```

### 10.2 Loading Scenarios

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  topic :greeting do
    characteristic "Initial contact phase"
  end
  
  topic :gathering_details do
    characteristic "Collecting event requirements"
  end
  
  scenario_set "venue_searches", from: "scenarios/venue_search.json" do |scenario|
    it "handles #{scenario[:name]}" do
      expect_conversation_to do
        use_topic :greeting, next: :gathering_details
        use_topic :gathering_details
      end
      
      user.simulate do
        goal scenario[:goal]
        personality scenario[:personality]
        context { scenario[:context].each { |c| note c } }
      end
    end
  end
end
```

### 10.3 Inline Scenarios (Array-Based)

Scenarios can be defined directly in the test file using the `scenarios:` parameter instead of loading from a JSON file. This is useful for self-contained test files or when scenarios are dynamically generated.

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  topic :greeting do
    characteristic "Initial contact phase"
  end

  topic :gathering_details do
    characteristic "Collecting event requirements"
  end

  scenarios = [
    {
      id: "weihnachtsfeier",
      name: "Unternehmens-Weihnachtsfeier",
      goal: "Eine festliche Weihnachtsfeier für 60 Mitarbeiter in Berlin organisieren",
      personality: "Festlich gestimmt, achtet auf Details wie Dekoration und Menü",
      context: ["Dezember-Termin", "Abendveranstaltung mit Dinner", "Unterhaltungsprogramm gewünscht"]
    },
    {
      id: "produktlaunch",
      name: "Produktlaunch-Event",
      goal: "Ein Produktlaunch-Event für 100 Gäste in Hamburg organisieren",
      personality: "Marketing-orientiert, achtet auf Präsentationstechnik und Impression",
      context: ["Presse und Kunden eingeladen", "Moderne Location gewünscht", "Catering wichtig"]
    },
    {
      id: "vertriebstagung",
      name: "Vertriebstagung",
      goal: "Eine zweitägige Vertriebstagung für 50 Außendienstmitarbeiter in Düsseldorf",
      personality: "Ergebnisorientiert, fokussiert auf Motivation und Schulung",
      context: ["Motivationstraining geplant", "Award-Verleihung am Abend", "Networking wichtig"]
    }
  ]

  scenario_set "corporate_events", scenarios: scenarios do |scenario|
    it "handles #{scenario[:name]}" do
      expect_conversation_to do
        use_topic :greeting, next: :gathering_details
        use_topic :gathering_details
      end

      user.simulate do
        goal scenario[:goal]
        personality scenario[:personality]
        context { scenario[:context].each { |c| note c } }
      end
    end
  end
end
```

Both `from:` (file path) and `scenarios:` (inline array) provide identical functionality—choose based on whether scenarios are shared across files (use JSON) or specific to a single test file (use inline).

### 10.4 Nesting Within Contexts

```ruby
context "rushed users" do
  simulator do
    personality "Impatient, tight deadline"
    max_turns 8
  end

  scenario_set "urgent_bookings", from: "scenarios/urgent.json" do |scenario|
    it "handles #{scenario[:name]}" do
      user.simulate do
        goal scenario[:goal]
      end
    end
  end
end
```

### 10.5 Scenario-Specific Verification

```ruby
scenario_set "service_additions", from: "scenarios/add_services.json" do |scenario|
  it "handles #{scenario[:name]}" do
    user.simulate do
      goal scenario[:goal]
    end
    
    expect_conversation_to do
      use_topic :greeting, next: :service_selection
      use_topic :service_selection, next: :confirmation
      use_topic :confirmation
    end
    
    # Hard expectations for verification
    scenario[:verification][:expected_services].each do |service|
      expect(conversation).to have_tool_call(:add_service, service_type: service)
    end
  end
end
```

---

## 11. Goal Completion

Goal completion maps directly to RSpec pass/fail based on hard expectations only:

- **Test passes** (no hard expectation failures) → goal completed
- **Test fails** (any hard expectation fails) → goal not completed

Soft evaluation failures do **not** affect goal completion.

### 11.1 Implicit Completion

If test completes without hard expectation failures, goal is achieved:

```ruby
it "handles basic flow" do
  user.simulate do
    goal "Get information about venue options"
  end
  
  expect_conversation_to do
    use_topic :greeting, next: :presenting_results
    use_topic :presenting_results
  end
  # No hard assertions = success if no errors
end
```

### 11.2 Assertion-Based Completion

```ruby
it "completes booking flow" do
  user.simulate do
    goal "Book a venue"
  end
  
  expect_conversation_to do
    use_topic :greeting, next: :booking
    use_topic :booking, next: :confirmation
    use_topic :confirmation
  end
  
  # Hard expectations determine pass/fail
  expect(conversation).to have_reached_topic(:confirmation)
  expect(conversation).to have_tool_call(:book_venue)
  expect(conversation.turn_count).to be <= 10
end
```

### 11.3 Completion States

| State | Description |
|-------|-------------|
| `pass` | No hard expectation failures |
| `fail` | At least one hard expectation failed |

Failure metadata includes `failure_type` (`:assertion`, `:error`, `:timeout`, `:max_turns`), `failure_message`, `final_topic`, and `turn_count`.

---

## 12. Conversation Object

The `conversation` object accumulates state throughout a test.

### 12.1 Properties

| Property | Type | Description |
|----------|------|-------------|
| `messages` | Array<Message> | All messages (user and agent) |
| `turns` | Array<Turn> | Turn objects (user + agent pair) |
| `all_tool_calls` | Array<ToolCall> | All tool calls across turns |
| `current_topic` | Symbol \| nil | Current topic (when tracking enabled) |
| `topic_history` | Array<Symbol> | Topics visited |
| `evaluation_results` | Array<EvaluationResult> | All soft evaluation outcomes |

### 12.2 Methods

| Method | Description |
|--------|-------------|
| `has_tool_call?(name)` | True if any turn called the tool |
| `called_tool?(name)` | Count of calls to the tool |
| `in_topic?(name)` | True if currently in topic |
| `tool_calls_for(name)` | All calls to specific tool |

### 12.3 Messages

| Property | Type | Description |
|----------|------|-------------|
| `role` | Symbol | `:user` or `:agent` |
| `content` | String | Message text |
| `timestamp` | Time | When sent/received |
| `tool_calls` | Array | Tool calls (agent only) |
| `metadata` | Hash | Provider-specific data |

---

## 13. Complete Examples

### 13.1 Simulated Conversation

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"
  criterion :helpful, "The agent should help achieve the user's goal"
  
  simulator do
    role "Corporate event planner"
    max_turns 15
    stop_when { |turn, conv| conv.has_tool_call?(:book_venue) }
  end
  
  topic :greeting do
    characteristic "Initial contact phase"
    agent_intent "Welcome the user and establish rapport"
    evaluate_agent to_satisfy: [:friendly]
    forbid_claims :venues, :pricing
  end
  
  topic :gathering_details do
    characteristic "Collecting event requirements"
    agent_intent "Collect sufficient information for venue search"
    evaluate_agent to_satisfy: [:friendly, :helpful]
    forbid_claims :venues
  end
  
  topic :presenting_results do
    characteristic "Presenting venue options"
    triggers { on_tool_call :search_suppliers }
    agent_intent "Help user understand options using search results"
    evaluate_agent to_satisfy: [:helpful]
    evaluate_grounding :venues, :pricing, from_tools: [:search_suppliers]
    expect_tool_call :search_suppliers
  end
  
  it "handles standard venue search" do
    expect_conversation_to do
      use_topic :greeting, next: :gathering_details
      use_topic :gathering_details, next: :presenting_results
      use_topic :presenting_results, next: :gathering_details
    end
    
    user.simulate do
      goal "Find a venue for a corporate workshop with 50 attendees in Stuttgart"
    end

    expect(conversation.turns.count).to be >= 3
    expect(conversation.topic_history).to include(:presenting_results)
  end
end
```

### 13.2 Scripted Conversation

```ruby
RSpec.describe "Room Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"
  criterion :acknowledges_change, "Acknowledges modification requests gracefully"
  
  it "handles booking with modification" do
    user.says "Hi, I need to book a meeting room"
    
    evaluate(agent).to satisfy(:friendly)
    evaluate(agent).to have_intent(:gather_requirements)
    expect(agent).not_to call_tool(:book_room)
    expect(agent).not_to claim(:availability)
    
    user.says "The Blue Room for tomorrow at 2pm, 10 people"
    
    expect(agent).to call_tool(:check_availability).with(
      room: "Blue Room",
      capacity: 10
    )
    evaluate(agent).to be_grounded_in(:room_catalog, :calendar)
    
    user.says "Actually, make it 3pm instead"
    
    evaluate(agent).to satisfy(:acknowledges_change)
    expect(agent).to call_tool(:check_availability)
    evaluate(agent).to match(/3[:\s]?00\s*pm|15[:\s]?00/i)
    
    user.says "Yes, please book it"
    
    expect(agent).to call_tool(:book_room)
    evaluate(agent).to be_grounded_in(:booking_confirmation)
    evaluate(agent).to satisfy(:friendly)
    
    expect(conversation.turns.count).to eq(4)
    expect(conversation.all_tool_calls.map(&:name)).to include(
      :check_availability, :book_room
    )
  end
end
```

### 13.3 Scripted with Topic Tracking

```ruby
RSpec.describe "Room Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"
  
  topic :greeting do
    characteristic "Initial contact and welcome"
  end
  
  topic :gathering_details do
    characteristic "Collecting booking requirements"
  end
  
  topic :confirming do
    characteristic "Confirming and finalizing the booking"
  end
  
  it "progresses through booking flow" do
    expect_conversation_to do
      use_topic :greeting, next: :gathering_details
      use_topic :gathering_details, next: :confirming
      use_topic :confirming
    end
    
    user.says "Hello!"
    
    expect(agent).to be_in_topic(:greeting)
    evaluate(agent).to satisfy(:friendly)
    
    user.says "I need the Blue Room for 10 people tomorrow"
    
    expect(agent).to be_in_topic(:gathering_details)
    expect(conversation.topic_history).to eq([:greeting, :gathering_details])
    expect(agent).to call_tool(:check_availability)
    
    user.says "Yes, book it"
    
    expect(agent).to be_in_topic(:confirming)
    expect(agent).to call_tool(:book_room)
  end
end
```
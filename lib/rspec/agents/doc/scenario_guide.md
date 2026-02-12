# RSpec Agents Scenario Guide

This guide provides practical examples for writing agent tests using the rspec-agents DSL.

## Quick Reference

### Criteria Types

```ruby
# 1. Named criterion (defined at describe/context level)
criterion :friendly, "The agent's response should be friendly"
expect(agent).to satisfy(:friendly)

# 2. Adhoc criterion (inline string description, evaluated by LLM)
expect(agent).to satisfy("Der Agent fragt nach Details oder zeigt das Formular an")

# 3. Lambda criterion (code-based, no LLM)
expect(agent).to satisfy(->(turn) { turn.agent_response.text.length <= 500 })

# 4. Named lambda criterion
expect(agent).to satisfy(:concise, ->(turn) { turn.agent_response.text.length <= 300 })
```

### Soft vs Hard Assertions

```ruby
# Soft: records result, continues even if fails
evaluate(agent).to satisfy(:friendly)

# Hard: test fails immediately if not met
expect(agent).to satisfy(:friendly)
```

---

## Common Patterns

### Basic Scripted Conversation

```ruby
RSpec.describe "Room Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"

  it "handles booking request" do
    user.says "Hi, I need to book a meeting room"

    evaluate(agent).to satisfy(:friendly)
    expect(agent).not_to call_tool(:book_room)

    user.says "The Blue Room for tomorrow at 2pm"

    expect(agent).to call_tool(:check_availability)
  end
end
```

### Using Adhoc Criterions

Adhoc criterions are useful when you need a one-off evaluation without defining a named criterion. The string description is passed directly to the LLM judge.

```ruby
it "handles form display" do
  user.says "I want to book a room"

  # German description - LLM evaluates naturally
  expect(agent).to satisfy("Der Agent fragt nach Details oder zeigt das Formular an")

  # English description
  evaluate(agent).to satisfy("The agent acknowledges the request")

  # Mix named and adhoc
  evaluate(agent).to satisfy(:friendly)
  expect(agent).to satisfy("Response contains actionable next steps")
end
```

### Combining Criterion Types

```ruby
it "validates response quality" do
  user.says "Search for venues in Stuttgart"

  # Named criterion
  evaluate(agent).to satisfy(:friendly)

  # Adhoc criterion for specific requirement
  expect(agent).to satisfy("The agent confirms the search location")

  # Lambda for deterministic checks
  expect(agent).to satisfy(->(turn) {
    turn.agent_response.tool_calls.any? { |tc| tc.name == :search_venues }
  })

  # Multiple in one call
  evaluate(agent).to satisfy(
    :helpful,
    "Response is professional",
    ->(turn) { turn.agent_response.text.length < 1000 }
  )
end
```

### Scenario-Based Testing (from JSON file)

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"
  criterion :helpful, "The agent should move toward the user's goal"

  scenario_set "venue_searches", from: "scenarios/venue_search.json" do |scenario|
    it "handles #{scenario[:name]}" do
      user.simulate do
        goal scenario[:goal]
        personality scenario[:personality]
      end

      # Adhoc criterion using scenario data
      expect(agent).to satisfy("The agent addresses: #{scenario[:goal]}")
    end
  end
end
```

### Scenario-Based Testing (inline array)

Scenarios can be defined directly in the test file using `scenarios:` instead of `from:`. This is useful for self-contained tests or dynamically generated scenarios.

```ruby
RSpec.describe "Event Booking Agent", type: :agent do
  criterion :friendly, "The agent's response should be friendly"
  criterion :helpful, "The agent should move toward the user's goal"

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
    },
    {
      id: "klausurtagung",
      name: "Management-Klausurtagung",
      goal: "Eine vertrauliche Klausurtagung für 12 Führungskräfte in einem ruhigen Hotel im Schwarzwald",
      personality: "Diskret, bevorzugt ruhige und abgeschiedene Locations",
      context: ["Strategische Themen", "Absolute Vertraulichkeit", "Keine Ablenkungen"]
    },
    {
      id: "azubi_onboarding",
      name: "Azubi-Onboarding",
      goal: "Ein Onboarding-Event für 20 neue Auszubildende in der Nähe von München",
      personality: "Jugendlich, achtet auf abwechslungsreiches Programm",
      context: ["Junge Teilnehmer", "Teambuilding-Aktivitäten wichtig", "Lockere Atmosphäre"]
    }
  ]

  scenario_set "corporate_events", scenarios: scenarios do |scenario|
    it "handles #{scenario[:name]}" do
      user.simulate do
        goal scenario[:goal]
        personality scenario[:personality]
        context { scenario[:context].each { |c| note c } }
      end

      evaluate(agent).to satisfy(:friendly)
      evaluate(agent).to satisfy(:helpful)
    end
  end
end
```

**When to use each approach:**

| Approach | Use When |
|----------|----------|
| `from: "file.json"` | Scenarios shared across multiple test files |
| `scenarios: [...]` | Self-contained tests, dynamically generated scenarios |

---

## When to Use Each Criterion Type

| Type | Use When | Example |
|------|----------|---------|
| Named | Reused across multiple tests | `:friendly`, `:helpful` |
| Adhoc | One-off, test-specific requirement | `"Der Agent zeigt das Formular an"` |
| Lambda | Deterministic, no LLM needed | `->(turn) { turn.text.length < 500 }` |
| Named Lambda | Reusable code check with a name | `:concise, ->(turn) { ... }` |

### Adhoc Criterion Best Practices

1. **Use natural language**: Write descriptions as you would explain to a human
2. **Be specific**: "The agent asks for the event date" is better than "Agent asks questions"
3. **Language flexibility**: Use any language - the LLM judge handles German, English, etc.
4. **Mix with named criteria**: Use adhoc for edge cases, named for common patterns

```ruby
# Good: specific, actionable
expect(agent).to satisfy("The agent provides at least 3 venue options")
expect(agent).to satisfy("Der Agent fragt nach dem Budget")

# Avoid: too vague
expect(agent).to satisfy("Good response")
expect(agent).to satisfy("Agent works correctly")
```

---

## Tool Call Assertions

```ruby
# Basic tool call check
expect(agent).to call_tool(:search_venues)

# With parameters
expect(agent).to call_tool(:book_room).with(
  room: "Blue Room",
  capacity: be >= 10
)

# Negated
expect(agent).not_to call_tool(:book_room)

# Conversation-level (across all turns)
expect(conversation).to have_tool_call(:search_venues)
```

---

## Grounding Assertions

```ruby
# Verify claims are grounded in tool results
expect(agent).to be_grounded_in(:venues, :pricing)

# Specify source tools
expect(agent).to be_grounded_in(:venues, from_tools: [:search_venues])

# Forbid ungrounded claims
expect(agent).not_to claim(:availability)
```

---

## Topic Tracking

**No self-loops:** A topic cannot list itself in `next:`. The tracker stays in a topic until a transition occurs naturally.

```ruby
it "progresses through booking flow" do
  expect_conversation_to do
    use_topic :greeting, next: :gathering_details
    use_topic :gathering_details, next: :confirming
    use_topic :confirming
  end

  user.says "Hello!"
  expect(agent).to be_in_topic(:greeting)

  user.says "I need a room for 10 people tomorrow"
  expect(agent).to be_in_topic(:gathering_details)
end
```

---

## Goal Achievement

```ruby
# Check stated goal (from simulator config)
expect(agent).to have_achieved_stated_goal

# Check custom goal description
expect(agent).to have_achieved_goal("User received venue options under budget")
```

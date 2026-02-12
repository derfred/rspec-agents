# rspec-agents-studio: Product Design Document

## 1. Executive Summary

rspec-agents-studio is a visual interface layer built on top of the rspec-agents testing framework. It transforms the developer-centric CLI workflow into an accessible platform for test authoring, execution monitoring, result analysis, and iterative improvement of conversational AI agents.

The product serves three primary functions:

1. **Analysis Dashboard**: Visualise test results, aggregation statistics, and conversation flow through topic graphs
2. **Experiment Tracking**: Manage experimental runs as first-class entities with configuration versioning and comparison tools
3. **AI-Assisted Authoring**: Integrate Claude to help users explore data, understand patterns, and generate test specifications

---

## 2. Target Users

### Primary: Conversational AI Product Managers

Product managers responsible for agent quality who may not write Ruby code daily. They need to:
- Define test scenarios in natural language
- Understand where agents fail and why
- Track quality trends over time
- Make go/no-go decisions on agent releases

### Secondary: Conversational AI Engineers

Engineers who build and tune agents. They need to:
- Debug specific conversation failures
- Identify patterns across failures
- Iterate quickly on prompt changes
- Compare experimental configurations

### Tertiary: QA Teams

Quality assurance specialists who need to:
- Build regression test suites
- Monitor agent behaviour across releases
- Generate reports for stakeholders

---

## 3. Core Product Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         rspec-agents-studio                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │   Analysis   │  │  Experiment  │  │     AI       │  │    Test      │ │
│  │  Dashboard   │  │   Tracker    │  │   Copilot    │  │   Runner     │ │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
│         │                 │                 │                 │          │
│         └─────────────────┴────────┬────────┴─────────────────┘          │
│                                    │                                     │
│                          ┌─────────▼─────────┐                           │
│                          │   Studio Backend   │                          │
│                          │    (Rails API)     │                          │
│                          └─────────┬─────────┘                           │
│                                    │                                     │
└────────────────────────────────────┼─────────────────────────────────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
           ┌────────▼────────┐ ┌─────▼─────┐ ┌───────▼───────┐
           │    PostgreSQL   │ │  Claude   │ │  rspec-agents │
           │    (Storage)    │ │    API    │ │   (Runner)    │
           └─────────────────┘ └───────────┘ └───────────────┘
```

### 3.1 Component Overview

| Component | Responsibility |
|-----------|----------------|
| Analysis Dashboard | Visualise results, topic graphs, conversation flows |
| Experiment Tracker | Version configurations, compare runs, track trends |
| AI Copilot | Natural language interface for data exploration and spec generation |
| Test Runner | Execute rspec-agents suites, stream results to backend |
| Studio Backend | API layer, data persistence, Claude integration |

---

## 4. Analysis Dashboard

### 4.1 Overview Screen

The landing view after selecting an experiment shows high-level health metrics:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Experiment: "Prompt v2.3 - Grounding Focus"                            │
│  Run: 2025-01-16 14:30 UTC  •  47 scenarios  •  Branch: feature/ground  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │ Completion  │  │   Avg       │  │  Criteria   │  │  Grounding  │     │
│  │   78.7%     │  │   Turns     │  │   Health    │  │    Score    │     │
│  │  ▲ +6.4pp   │  │    5.4      │  │   87.2%     │  │   81.3%     │     │
│  │  vs baseline│  │  ▼ -0.8     │  │  ▲ +2.1pp   │  │  ▲ +12.4pp  │     │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘     │
│                                                                          │
│  ┌─────────────────────────────────┐  ┌─────────────────────────────┐   │
│  │      Scenario Results          │  │    Criteria Breakdown       │   │
│  │  ┌─────────────────────────┐   │  │                             │   │
│  │  │ ████████████████░░░░░░  │   │  │  friendly      ████████░ 94%│   │
│  │  │ 37 passed    10 failed  │   │  │  helpful       ███████░░ 89%│   │
│  │  └─────────────────────────┘   │  │  grounded      ██████░░░ 76%│   │
│  │                                │  │  concise       ██████░░░ 82%│   │
│  │  Failed scenarios:             │  │                             │   │
│  │  • budget_conscious (details)  │  │                             │   │
│  │  • first_time_user (details)   │  │                             │   │
│  │  • complex_requirements ...    │  │                             │   │
│  └─────────────────────────────────┘  └─────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Topic Graph Visualisation

Interactive visualisation of the expected conversation flow with actual traversal overlay:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Topic Graph: venue_search scenarios (47 runs)                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│                        ┌───────────┐                                     │
│                        │ greeting  │                                     │
│                        │  47/47    │ ← All scenarios entered here        │
│                        └─────┬─────┘                                     │
│                              │ 100%                                      │
│                              ▼                                           │
│                    ┌─────────────────┐                                   │
│                    │gathering_details│                                   │
│                    │     45/47       │ ← 2 failed here                   │
│                    └────┬───────┬────┘                                   │
│                    85%  │       │ 15%                                    │
│                         ▼       ▼                                        │
│  ┌───────────────────────┐   ┌───────────────────┐                      │
│  │  presenting_results   │   │ needs_clarification│                      │
│  │        38/45          │   │       7/45         │                      │
│  └───────────┬───────────┘   └─────────┬─────────┘                      │
│              │ 97%                     │ 100%                            │
│              ▼                         │                                 │
│  ┌───────────────────────┐             │                                │
│  │ booking_confirmation  │◄────────────┘                                │
│  │        37/47          │ ← Goal topic                                 │
│  └───────────────────────┘                                              │
│                                                                          │
│  Legend: [Topic Name]  Visits/Total  Edge: transition %                 │
│          Red border = high failure rate    Dashed = rare path           │
│                                                                          │
│  [View as Sankey] [View as Heatmap] [Export SVG]                        │
└─────────────────────────────────────────────────────────────────────────┘
```

**Interactions:**
- Click a topic node to see criteria pass rates for turns in that topic
- Click an edge to see which scenarios took that path
- Filter by scenario outcome (passed/failed)
- Animate individual scenario traversals

### 4.3 Scenario Deep Dive

Drill into a specific scenario to see the full conversation:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Scenario: budget_conscious                                    [FAILED] │
│  Goal: "Find a venue under 20,000 EUR for 30 attendees"                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Conversation Timeline                          │ Turn Analysis          │
│  ─────────────────────────────────────────────  │ ─────────────────────  │
│                                                 │                        │
│  Turn 1 [greeting]                              │ Turn 4 selected        │
│  ├─ User: "Hi, I need to book a venue..."       │                        │
│  └─ Agent: "Welcome! I'd be happy to help..."   │ Criteria:              │
│     ✓ friendly  ✓ helpful                       │  ✓ friendly            │
│                                                 │  ✗ grounded_pricing    │
│  Turn 2 [gathering_details]                     │  ✓ helpful             │
│  ├─ User: "It's for 30 people, budget is..."   │                        │
│  └─ Agent: "Got it! Let me search for..."       │ Tool Calls:            │
│     ✓ friendly  ✓ helpful                       │  • search_suppliers    │
│                                                 │    location: "Berlin"  │
│  Turn 3 [presenting_results]                    │    budget: 20000       │
│  ├─ User: "Those look good, what about..."      │    → 3 results         │
│  └─ Agent: "Here are some options..."           │                        │
│     ✓ friendly  ✓ grounded  ✓ helpful          │ Grounding Analysis:    │
│                                                 │  Claim: "around 18k"   │
│  Turn 4 [presenting_results]               ◄── │  Tool result: 22,500   │
│  ├─ User: "What's the pricing like?"            │  Verdict: UNGROUNDED   │
│  └─ Agent: "The pricing is around 18,000..."    │                        │
│     ✓ friendly  ✗ grounded_pricing  ✓ helpful  │ Agent Intent:          │
│                                                 │  Expected: Present     │
│  Turn 5 [presenting_results]                    │    accurate pricing    │
│  ├─ User: "That sounds perfect, let's book"     │  Actual: Provided      │
│  └─ Agent: "I'll need to confirm availability"  │    approximate figure  │
│                                                 │                        │
│  [MAX_TURNS reached - did not complete]         │ [View Raw JSON]        │
│                                                 │ [Replay with Debugger] │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.4 Criteria Drill-Down

Analyse a specific criterion across all scenarios:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Criterion: grounded_pricing                                            │
│  "Pricing information must be grounded in tool call results"            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Overall: 76.3% pass rate (87/114 evaluations)                          │
│                                                                          │
│  By Topic:                           │  Failure Patterns:               │
│  ┌────────────────────────────────┐  │  ┌─────────────────────────────┐ │
│  │ presenting_results    71.2%   │  │  │ • Approximate figures (12) │ │
│  │ ████████████████░░░░░░░░░░░░  │  │  │ • Outdated pricing (8)     │ │
│  │                                │  │  │ • Aggregation errors (5)   │ │
│  │ booking_confirmation  89.4%   │  │  │ • No source cited (2)      │ │
│  │ ████████████████████████░░░░  │  │  └─────────────────────────────┘ │
│  └────────────────────────────────┘  │                                  │
│                                      │  Common failure scenarios:       │
│  Trend (last 5 experiments):         │  • budget_conscious              │
│  ┌────────────────────────────────┐  │  • complex_requirements          │
│  │     •                          │  │  • urgent_booking                │
│  │    • •                         │  │                                  │
│  │   •   •                    •   │  │  [View All Failures]             │
│  │  •         •   •   •   •      │  │  [Generate Improvement Report]   │
│  │ 60%────────────────────────90%│  │                                  │
│  └────────────────────────────────┘  │                                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Experiment Tracking

### 5.1 Experiment List

Central registry of all experimental runs:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Experiments                                        [+ New Experiment]  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Filter: [All ▼] [Last 30 days ▼] [Branch: all ▼]  Search: [________]   │
│                                                                          │
│  ┌─────┬────────────────────────┬──────────┬────────┬────────┬────────┐ │
│  │ ★   │ Name                   │ Date     │ Compl. │ Branch │ Status │ │
│  ├─────┼────────────────────────┼──────────┼────────┼────────┼────────┤ │
│  │ ●   │ Prompt v2.3 grounding  │ Jan 16   │ 82.9%  │ feat/g │ ✓ Done │ │
│  │     │ Prompt v2.2 baseline   │ Jan 15   │ 76.5%  │ main   │ ✓ Done │ │
│  │     │ Prompt v2.1 friendly   │ Jan 14   │ 74.2%  │ main   │ ✓ Done │ │
│  │ ●   │ Prompt v2.0 initial    │ Jan 10   │ 68.1%  │ main   │ ✓ Done │ │
│  │     │ [Draft] New scenarios  │ Jan 16   │ -      │ -      │ Draft  │ │
│  └─────┴────────────────────────┴──────────┴────────┴────────┴────────┘ │
│                                                                          │
│  ★ = Baseline    ● = Pinned                                             │
│                                                                          │
│  [Compare Selected] [Set Baseline] [Export Report]                      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Experiment Configuration

Each experiment captures its full configuration for reproducibility:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Experiment Configuration: "Prompt v2.3 grounding"                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─ Identity ────────────────────────────────────────────────────────┐  │
│  │ ID:        exp_def456                                             │  │
│  │ Created:   2025-01-16 14:30:00 UTC                                │  │
│  │ Git:       abc123def (feature/grounding) [clean]                  │  │
│  │ Tags:      grounding-focus, iteration-3                           │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─ Test Configuration ──────────────────────────────────────────────┐  │
│  │ Scenario Set:    venue_search.json (47 scenarios)                 │  │
│  │ Topic Graph:     sha256:8f3a... [View Graph]                      │  │
│  │ Criteria:        sha256:2b1c... [View Definitions]                │  │
│  │ Simulator:       max_turns=15, role="Corporate planner"           │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─ LLM Configuration ───────────────────────────────────────────────┐  │
│  │ Agent:           Production API (https://agent.example.com)       │  │
│  │ Judge LLM:       claude-sonnet-4-20250514                              │  │
│  │ Simulator LLM:   claude-sonnet-4-20250514                              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─ Prompt Versions ─────────────────────────────────────────────────┐  │
│  │ Agent System:    v2.3 [View Diff vs Baseline]                     │  │
│  │ Judge System:    v1.0 (unchanged)                                 │  │
│  │ Simulator:       v1.2 [View Diff vs Baseline]                     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  [Clone Experiment] [Edit & Re-run] [Delete]                            │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.3 Experiment Comparison

Side-by-side comparison of two experiments:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Compare: Prompt v2.2 (baseline) → Prompt v2.3 (current)               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Configuration Changes:                                                  │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ ✓ Topic Graph:    Identical                                       │  │
│  │ ✓ Criteria:       Identical                                       │  │
│  │ ⚠ Scenarios:      45 shared, 2 added, 1 removed                   │  │
│  │ ✓ Judge LLM:      Identical                                       │  │
│  │ △ Agent Prompt:   Changed [View Diff]                             │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  Results Comparison (45 shared scenarios):                              │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                        Baseline    Current     Delta              │  │
│  │ Completion Rate        76.5%       82.9%       +6.4pp  ▲          │  │
│  │ Avg Turns              6.2         5.4         -0.8    ▲          │  │
│  │ :friendly              95.0%       94.0%       -1.0pp  ─          │  │
│  │ :helpful               88.0%       91.0%       +3.0pp  ▲          │  │
│  │ :grounded_pricing      72.0%       89.0%       +17.0pp ▲▲         │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  Scenario Changes:                                                       │
│  ┌─ Newly Passing (2) ───┐  ┌─ Newly Failing (1) ───┐                  │
│  │ • corporate_munich    │  │ • budget_conscious    │                  │
│  │ • urgent_booking      │  │   Was: 7 turns, pass  │                  │
│  │                       │  │   Now: fails at       │                  │
│  │                       │  │   gathering_details   │                  │
│  └───────────────────────┘  └───────────────────────┘                  │
│                                                                          │
│  [View Topic Graph Diff] [Generate Report] [Promote to Baseline]        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.4 Trend Analysis

Track metrics over time across experiments:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Trend Analysis: Completion Rate                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  100% ┤                                                                  │
│       │                                                                  │
│   90% ┤                                              ●────●              │
│       │                                         ●───●                    │
│   80% ┤                                    ●───●                         │
│       │                               ●───●                              │
│   70% ┤                          ●───●                                   │
│       │                     ●───●                                        │
│   60% ┤                ●───●                                             │
│       │           ●───●                                                  │
│   50% ┤      ●───●                                                       │
│       │ ●───●                                                            │
│   40% ┼────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼────┼     │
│       v1.0 v1.1 v1.2 v1.3 v1.4 v1.5 v1.6 v1.7 v1.8 v1.9 v2.0 v2.1 v2.2 │
│                                                                          │
│  Annotations:                                                            │
│  • v1.5: Added grounding criteria                                       │
│  • v1.8: Refactored topic graph                                         │
│  • v2.0: New prompt structure                                           │
│                                                                          │
│  [Add Annotation] [Export Data] [Change Metric]                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. AI Copilot

### 6.1 Overview

The AI Copilot provides a conversational interface powered by Claude that can:
- Query the experiment database using natural language
- Analyse patterns across test results
- Generate test specifications based on descriptions
- Suggest improvements based on failure analysis

### 6.2 Chat Interface

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AI Copilot                                            [Context: All]   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─ Conversation ────────────────────────────────────────────────────┐  │
│  │                                                                    │  │
│  │  You: Which scenarios have the worst grounding scores?            │  │
│  │                                                                    │  │
│  │  Claude: Based on your last 5 experiments, the scenarios with     │  │
│  │  consistently poor grounding scores are:                          │  │
│  │                                                                    │  │
│  │  1. **budget_conscious** - 52% avg grounding (pricing claims)     │  │
│  │  2. **complex_requirements** - 61% avg grounding (venue details)  │  │
│  │  3. **urgent_booking** - 67% avg grounding (availability)         │  │
│  │                                                                    │  │
│  │  The common pattern is these scenarios involve multi-step         │  │
│  │  information gathering where the agent seems to interpolate       │  │
│  │  between tool results rather than citing specific values.         │  │
│  │                                                                    │  │
│  │  Would you like me to:                                            │  │
│  │  • Show specific ungrounded claims from these scenarios?          │  │
│  │  • Generate a new criterion to catch this pattern?                │  │
│  │  • Create a focused test scenario for this failure mode?          │  │
│  │                                                                    │  │
│  │  ──────────────────────────────────────────────────────────────   │  │
│  │                                                                    │  │
│  │  You: Show me the ungrounded claims from budget_conscious         │  │
│  │                                                                    │  │
│  │  Claude: Here are the ungrounded claims from the last 3 runs      │  │
│  │  of budget_conscious:                                             │  │
│  │                                                                    │  │
│  │  | Run      | Turn | Claim                    | Tool Result       │  │
│  │  |----------|------|--------------------------|-------------------|  │
│  │  | exp_def4 | 4    | "around 18,000 EUR"      | 22,500 EUR        │  │
│  │  | exp_abc1 | 5    | "within your budget"     | 21,000 EUR        │  │
│  │  | exp_789x | 4    | "approximately 18-20k"   | 22,500, 24,000    │  │
│  │                                                                    │  │
│  │  The agent consistently underestimates prices by ~15-20%.         │  │
│  │                                                                    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ Ask about your test results...                            [Send]  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  Suggestions: [Compare to baseline] [Find regressions] [Suggest tests]  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Database Query Capabilities

The AI Copilot has tool access to query the studio database:

```ruby
# Tools available to the AI Copilot

# Search experiments
search_experiments(
  query: "grounding improvements",
  date_range: "last 30 days",
  branches: ["main", "feature/*"],
  min_scenarios: 40
)

# Get experiment details
get_experiment(id: "exp_def456")
get_experiment_comparison(baseline: "exp_abc123", current: "exp_def456")

# Query scenario results
search_scenarios(
  criterion: "grounded_pricing",
  outcome: "failed",
  experiments: ["exp_def456", "exp_abc123"]
)

# Get conversation details
get_conversation(experiment_id: "exp_def456", scenario_id: "budget_conscious")
get_turn_analysis(experiment_id: "exp_def456", scenario_id: "budget_conscious", turn: 4)

# Aggregate queries
get_criterion_trends(criterion: "friendly", experiments: "last_10")
get_topic_transition_stats(experiment_id: "exp_def456")

# Pattern analysis
find_similar_failures(scenario_id: "budget_conscious", experiment_id: "exp_def456")
get_failure_clusters(experiment_id: "exp_def456")
```

### 6.4 Spec Generation

The copilot can generate test specifications:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AI Copilot: Spec Generation                                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  You: Create a test scenario for users who change their requirements    │
│  mid-conversation, like first asking for a small venue then upgrading   │
│  to a larger one.                                                       │
│                                                                          │
│  Claude: I'll create a scenario for requirement changes. Here's what    │
│  I'm generating:                                                        │
│                                                                          │
│  ┌─ Generated Scenario ──────────────────────────────────────────────┐  │
│  │ ```json                                                           │  │
│  │ {                                                                 │  │
│  │   "id": "requirement_upgrade",                                    │  │
│  │   "name": "User upgrades venue requirements mid-flow",            │  │
│  │   "goal": "Initially find a venue for 20 people, then upgrade     │  │
│  │           to 50 people after seeing options",                     │  │
│  │   "context": [                                                    │  │
│  │     "Planning a corporate team event",                            │  │
│  │     "Budget is flexible if venue is right"                        │  │
│  │   ],                                                              │  │
│  │   "personality": "Indecisive, easily influenced by options",      │  │
│  │   "verification": {                                               │  │
│  │     "must_call_search_twice": true,                               │  │
│  │     "second_search_min_capacity": 50                              │  │
│  │   }                                                               │  │
│  │ }                                                                 │  │
│  │ ```                                                               │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  I'd recommend adding these criteria assertions:                        │
│  - `acknowledges_change`: Agent confirms the requirement update         │
│  - `no_stale_results`: Agent doesn't reference old search results      │
│                                                                          │
│  Should I also generate the RSpec test file for this scenario?          │
│                                                                          │
│  [Add to Scenario Set] [Generate RSpec] [Modify]                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.5 RSpec File Generation

When generating test specifications:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Generated: spec/agents/venue_search/requirement_changes_spec.rb        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ```ruby                                                                │
│  # frozen_string_literal: true                                          │
│  # Generated by rspec-agents-studio on 2025-01-16                       │
│  # Based on: "requirement_upgrade" scenario                             │
│                                                                          │
│  RSpec.describe "Venue Search Agent - Requirement Changes", type: :agent do
│    criterion :acknowledges_change, <<~DESC                              │
│      When the user changes their requirements, the agent explicitly     │
│      acknowledges the change before proceeding.                         │
│    DESC                                                                 │
│                                                                          │
│    criterion :no_stale_results, <<~DESC                                 │
│      After requirements change, the agent does not reference results    │
│      from searches that no longer match the new requirements.           │
│    DESC                                                                 │
│                                                                          │
│    topic :gathering_details do                                          │
│      characteristic "Collecting initial venue requirements"             │
│      agent_intent "Understand the user's basic needs"                   │
│    end                                                                  │
│                                                                          │
│    topic :presenting_results do                                         │
│      characteristic "Showing venue options based on requirements"       │
│      triggers { on_tool_call :search_suppliers }                        │
│    end                                                                  │
│                                                                          │
│    topic :handling_change do                                            │
│      characteristic "User has modified their requirements"              │
│      triggers { on_user_match /actually|change|instead|more people/i } │
│      expect_agent to_satisfy: [:acknowledges_change]                    │
│    end                                                                  │
│                                                                          │
│    scenario_set "requirement_changes",                                  │
│                 from: "scenarios/requirement_changes.json" do |scenario│
│      it "handles #{scenario[:name]}" do                                │
│        expect_conversation_to do                                        │
│          use_topic :gathering_details, next: :presenting_results        │
│          use_topic :presenting_results, next: [:handling_change]       │
│          use_topic :handling_change, next: :presenting_results         │
│                                                                          │
│          verify_goal do |conversation, data|                            │
│            searches = conversation.tool_calls_for(:search_suppliers)    │
│            return false unless searches.count >= 2                      │
│                                                                          │
│            second_search = searches[1]                                  │
│            second_search.arguments[:capacity] >=                        │
│              data[:verification][:second_search_min_capacity]          │
│          end                                                            │
│        end                                                              │
│                                                                          │
│        user.simulate do                                                 │
│          goal scenario[:goal]                                           │
│          personality scenario[:personality]                             │
│          context { scenario[:context].each { |c| note c } }            │
│        end                                                              │
│      end                                                                │
│    end                                                                  │
│  end                                                                    │
│  ```                                                                    │
│                                                                          │
│  [Save to Repo] [Copy to Clipboard] [Edit] [Run Test]                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Technical Architecture

### 7.1 Data Model

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Core Entities                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────┐       ┌─────────────┐       ┌─────────────┐            │
│  │ Experiment  │       │  Scenario   │       │   Result    │            │
│  ├─────────────┤       ├─────────────┤       ├─────────────┤            │
│  │ id          │       │ id          │       │ id          │            │
│  │ name        │──────<│ set_name    │──────<│ experiment_ │            │
│  │ timestamp   │       │ name        │       │ scenario_id │            │
│  │ git_commit  │       │ goal        │       │ passed      │            │
│  │ git_branch  │       │ context     │       │ turns       │            │
│  │ config_hash │       │ personality │       │ final_topic │            │
│  │ tags        │       │ verification│       │ termination │            │
│  └─────────────┘       └─────────────┘       └─────────────┘            │
│         │                                           │                    │
│         │              ┌─────────────┐              │                    │
│         │              │Configuration│              │                    │
│         │              ├─────────────┤              │                    │
│         └─────────────>│ experiment_ │              │                    │
│                        │ topic_graph │              │                    │
│                        │ criteria    │              │                    │
│                        │ simulator   │              │                    │
│                        │ llm_config  │              │                    │
│                        └─────────────┘              │                    │
│                                                     │                    │
│  ┌─────────────┐       ┌─────────────┐             │                    │
│  │    Turn     │       │ Evaluation  │             │                    │
│  ├─────────────┤       ├─────────────┤             │                    │
│  │ id          │<──────│ turn_id     │<────────────┘                    │
│  │ result_id   │       │ criterion   │                                  │
│  │ sequence    │       │ passed      │                                  │
│  │ topic       │       │ rationale   │                                  │
│  │ user_msg    │       │ evidence    │                                  │
│  │ agent_msg   │       └─────────────┘                                  │
│  │ tool_calls  │                                                        │
│  └─────────────┘                                                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 API Endpoints

```
# Experiments
GET    /api/experiments                    # List experiments
POST   /api/experiments                    # Create experiment
GET    /api/experiments/:id                # Get experiment details
DELETE /api/experiments/:id                # Delete experiment
GET    /api/experiments/:id/results        # Get all results
GET    /api/experiments/compare            # Compare two experiments

# Results
GET    /api/results/:id                    # Get result details
GET    /api/results/:id/conversation       # Get full conversation
GET    /api/results/:id/turns/:turn        # Get turn details

# Scenarios
GET    /api/scenarios                      # List scenario sets
POST   /api/scenarios                      # Create scenario set
GET    /api/scenarios/:set/items           # List scenarios in set

# Analysis
GET    /api/analysis/criteria/:name        # Criterion analysis
GET    /api/analysis/topics/:experiment    # Topic flow analysis
GET    /api/analysis/trends                # Trend data

# AI Copilot
POST   /api/copilot/chat                   # Send message to copilot
POST   /api/copilot/generate-spec          # Generate test spec
POST   /api/copilot/generate-scenario      # Generate scenario

# Test Runner
POST   /api/runner/start                   # Start test run
GET    /api/runner/:run_id/status          # Get run status
WS     /api/runner/:run_id/stream          # Stream results
```

### 7.3 Test Runner Integration

The test runner streams results to the studio backend during execution:

```ruby
# In rspec-agents configuration
RSpecAgents.configure do |config|
  config.studio_url = "https://studio.example.com"
  config.studio_token = ENV["STUDIO_TOKEN"]
  
  # Enable live streaming
  config.stream_results = true
end

# The runner sends events:
# - experiment_started
# - scenario_started
# - turn_completed (with evaluations)
# - scenario_completed
# - experiment_completed
```

### 7.4 Frontend Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Framework | React + TypeScript | Rich interactivity, type safety |
| State | TanStack Query | Server state management, caching |
| Routing | React Router | SPA navigation |
| Visualization | D3.js + Visx | Topic graph, Sankey diagrams |
| UI Components | Radix + Tailwind | Accessible, composable |
| Code Display | Monaco Editor | Syntax highlighting, editing |
| Real-time | WebSocket | Live test streaming |

---

## 8. User Workflows

### 8.1 Prompt Engineer Iteration Cycle

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Prompt Optimisation Workflow                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. BASELINE                                                            │
│     └─► Run test suite with current prompt                              │
│         └─► Mark as baseline in Studio                                  │
│                                                                          │
│  2. ANALYSE                                                             │
│     └─► Review Dashboard: identify low-performing criteria              │
│         └─► Use Copilot: "Which scenarios fail grounding?"              │
│             └─► Drill into specific failures                            │
│                 └─► Understand failure patterns                         │
│                                                                          │
│  3. HYPOTHESIZE                                                         │
│     └─► Formulate prompt change hypothesis                              │
│         └─► Use Copilot: "Generate a criterion to catch this"           │
│             └─► Add new assertions if needed                            │
│                                                                          │
│  4. IMPLEMENT                                                           │
│     └─► Modify agent prompt                                             │
│         └─► Commit to feature branch                                    │
│                                                                          │
│  5. TEST                                                                │
│     └─► Run test suite with new prompt                                  │
│         └─► Compare to baseline in Studio                               │
│             └─► If improved: merge and update baseline                  │
│             └─► If regressed: return to step 2                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.2 QA Regression Testing

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       QA Regression Workflow                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. NEW BUG REPORTED                                                    │
│     └─► "Agent gave wrong price to customer"                            │
│                                                                          │
│  2. CREATE REGRESSION TEST                                              │
│     └─► Use Copilot: "Create a scenario where user asks about           │
│         pricing for venues over 50,000 EUR"                             │
│         └─► Generate scenario JSON                                      │
│         └─► Generate RSpec file                                         │
│         └─► Verify test fails against current agent                     │
│                                                                          │
│  3. ADD TO SUITE                                                        │
│     └─► Add scenario to appropriate set                                 │
│         └─► Commit to test repository                                   │
│                                                                          │
│  4. VERIFY FIX                                                          │
│     └─► After fix deployed, run suite                                   │
│         └─► Confirm new scenario passes                                 │
│         └─► Confirm no regressions in other scenarios                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.3 Product Manager Quality Review

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       PM Quality Review Workflow                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. WEEKLY REVIEW                                                       │
│     └─► Open Trend Analysis view                                        │
│         └─► Review completion rate trend                                │
│         └─► Review criteria trends                                      │
│                                                                          │
│  2. IDENTIFY CONCERNS                                                   │
│     └─► Use Copilot: "Summarize quality changes this week"              │
│         └─► Get plain-language summary of changes                       │
│         └─► Identify any concerning regressions                         │
│                                                                          │
│  3. DEEP DIVE                                                           │
│     └─► Click through to specific failing scenarios                     │
│         └─► Review actual conversation transcripts                      │
│         └─► Understand user experience impact                           │
│                                                                          │
│  4. REPORT                                                              │
│     └─► Export comparison report                                        │
│         └─► Share with stakeholders                                     │
│         └─► Create tickets for identified issues                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Implementation Phases

### Phase 1: Foundation (4-6 weeks)

**Goal**: Basic experiment tracking and result viewing

- [ ] Data model and database schema
- [ ] Test runner integration (result streaming)
- [ ] Experiment list view
- [ ] Basic result dashboard (completion rates, criteria)
- [ ] Scenario deep-dive (conversation viewer)

**Milestone**: Can run tests, store results, view basic metrics

### Phase 2: Analysis (3-4 weeks)

**Goal**: Rich visualization and comparison tools

- [ ] Topic graph visualization
- [ ] Experiment comparison view
- [ ] Trend analysis charts
- [ ] Criteria drill-down views
- [ ] Export functionality (JSON, PDF reports)

**Milestone**: Full analysis workflow possible

### Phase 3: AI Copilot (4-6 weeks)

**Goal**: Natural language interface for data exploration

- [ ] Claude integration with tool access
- [ ] Chat interface
- [ ] Database query tools
- [ ] Pattern analysis tools
- [ ] Context management (current experiment, selection)

**Milestone**: Can ask questions about test results

### Phase 4: Spec Generation (3-4 weeks)

**Goal**: AI-assisted test authoring

- [ ] Scenario generation from descriptions
- [ ] RSpec file generation
- [ ] Criterion suggestion
- [ ] Integration with file system / git
- [ ] Validation and dry-run

**Milestone**: Can create new tests via conversation

### Phase 5: Polish & Scale (2-3 weeks)

**Goal**: Production readiness

- [ ] Performance optimization
- [ ] Multi-user support
- [ ] Authentication / authorization
- [ ] Audit logging
- [ ] Backup / restore

---

## 10. Success Metrics

| Metric | Target | Rationale |
|--------|--------|-----------|
| Time to first insight | < 5 min | Users should find value quickly |
| Test authoring time | 50% reduction | Copilot should accelerate test creation |
| Regression detection | < 1 day | Issues caught before production |
| Prompt iteration cycle | < 4 hours | Fast feedback enables experimentation |

---

## 11. Suggested Extensions

Beyond the core product, these extensions would significantly enhance the studio's value. They're ordered roughly by impact-to-effort ratio.

### 11.1 Live Debugging Mode

**Problem**: When a test fails, understanding *why* requires reconstructing the conversation context. Currently this means reading logs.

**Solution**: A replay debugger that lets you step through a conversation turn-by-turn, seeing:
- The exact prompt sent to the simulator LLM
- The simulator's reasoning for generating that user message
- The agent's response with tool call details
- The judge's evaluation with its reasoning chain
- What triggers were evaluated and why the topic was classified as it was

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Debugger: budget_conscious (Turn 4 of 7)                    [Paused]  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─ Simulator Decision ─────────────────────────────────────────────┐   │
│  │ Goal progress: 60% (found venues, need pricing)                  │   │
│  │ Persona: "budget-conscious, detail-oriented"                     │   │
│  │ Decision: Ask specifically about pricing to test grounding       │   │
│  │ Generated: "What's the pricing like for these venues?"           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌─ Agent Response ─────────────────────────────────────────────────┐   │
│  │ Tool: search_suppliers → 3 results (22500, 24000, 28000 EUR)     │   │
│  │ Response: "The pricing is around 18,000 EUR for most options"    │   │
│  │                        ▲                                          │   │
│  │                        └─ UNGROUNDED: no tool result near 18k     │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌─ Judge Evaluation ───────────────────────────────────────────────┐   │
│  │ grounded_pricing: FAIL                                            │   │
│  │ Reasoning: "Agent cited '18,000 EUR' but tool results show       │   │
│  │ minimum of 22,500 EUR. This is a significant understatement."    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  [◄ Prev] [Next ►] [Run to End] [Edit & Retry]                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Extension opportunity**: "Edit & Retry" would let you modify the user message or agent prompt and re-run from that point, creating a branched conversation for experimentation.

### 11.2 Failure Clustering & Root Cause Analysis

**Problem**: With 50+ scenarios, failures often share common root causes. Manually identifying patterns is tedious.

**Solution**: Automated clustering of failures using embedding similarity on:
- Agent responses that failed the same criterion
- Ungrounded claims
- Topic transition anomalies

The Copilot can then summarise clusters:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Failure Clusters (exp_def456)                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Cluster 1: "Price Approximation" (8 failures, 3 scenarios)             │
│  ──────────────────────────────────────────────────────────────────────  │
│  Pattern: Agent uses words like "around", "approximately", "roughly"    │
│  when stating prices, giving figures 10-20% below actual tool results.  │
│                                                                          │
│  Affected scenarios: budget_conscious, complex_requirements,            │
│                      first_time_user                                    │
│                                                                          │
│  Likely cause: Prompt instruction "be conversational" may encourage     │
│  rounding. Tool results show exact figures.                             │
│                                                                          │
│  Suggested fix: Add explicit instruction to cite exact prices from      │
│  search results.                                                        │
│                                                                          │
│  [View Examples] [Generate Criterion] [Create Issue]                    │
│                                                                          │
│  ──────────────────────────────────────────────────────────────────────  │
│                                                                          │
│  Cluster 2: "Premature Search" (4 failures, 2 scenarios)                │
│  ...                                                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.3 Automatic Scenario Generation from Production Logs

**Problem**: Test scenarios are hypothetical; real users may behave differently.

**Solution**: Import anonymised production conversation logs and:
1. Cluster conversations by flow patterns
2. Identify underrepresented patterns in test suite
3. Generate synthetic scenarios that match production distribution

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Production Coverage Analysis                                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Imported: 1,247 production conversations (last 30 days)               │
│  Clustered into: 23 distinct flow patterns                              │
│                                                                          │
│  Coverage Gaps:                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ Pattern                          │ Prod % │ Test Coverage │ Gap   │ │
│  ├────────────────────────────────────────────────────────────────────┤ │
│  │ Multi-venue comparison           │ 18%    │ 2 scenarios   │ HIGH  │ │
│  │ Booking modification             │ 12%    │ 0 scenarios   │ CRIT  │ │
│  │ Price negotiation attempt        │ 8%     │ 0 scenarios   │ HIGH  │ │
│  │ Unclear requirements → refine    │ 15%    │ 5 scenarios   │ OK    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  [Generate Scenarios for Gaps] [View Pattern Examples]                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.4 A/B Experiment Mode

**Problem**: Sometimes you want to compare two agent configurations on the *same* simulated conversation, not just the same scenarios.

**Solution**: "Forked conversation" mode where:
1. Both agent variants receive identical user messages (from the same simulator seed)
2. Results are displayed side-by-side
3. Differences are highlighted at the turn level

```
┌─────────────────────────────────────────────────────────────────────────┐
│  A/B Comparison: budget_conscious                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Turn 4: User asks "What's the pricing like?"                           │
│                                                                          │
│  ┌─ Agent A (baseline) ──────────┐  ┌─ Agent B (grounding v2) ────────┐ │
│  │                               │  │                                 │ │
│  │ "The pricing is around       │  │ "Based on the search results,  │ │
│  │ 18,000 EUR for most of       │  │ the three venues I found are   │ │
│  │ these options, which should  │  │ priced at €22,500, €24,000,    │ │
│  │ fit your budget nicely."     │  │ and €28,000 respectively."     │ │
│  │                               │  │                                 │ │
│  │ ✗ grounded_pricing           │  │ ✓ grounded_pricing              │ │
│  │ ✓ friendly                   │  │ ✓ friendly                      │ │
│  └───────────────────────────────┘  └─────────────────────────────────┘ │
│                                                                          │
│  Difference: Agent B cites exact figures; Agent A approximates          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.5 Continuous Monitoring & Alerting

**Problem**: Agent quality can drift over time (model updates, data drift, prompt decay).

**Solution**: Scheduled test runs with alerting:

```yaml
# .rspec-agents-studio/monitors.yml
monitors:
  - name: "Daily Regression"
    schedule: "0 6 * * *"  # 6am daily
    experiment_config: "configs/production.yml"
    scenario_set: "core_flows"
    
    alerts:
      - type: completion_rate
        threshold: 75%
        comparison: below
        notify: ["slack:#agent-alerts", "email:team@example.com"]
        
      - type: criterion
        name: grounded_pricing
        threshold: 80%
        comparison: below
        notify: ["slack:#agent-alerts"]
        
      - type: regression
        baseline: "latest_release"
        threshold: 5%  # >5% degradation
        notify: ["pagerduty:agent-oncall"]
```

Dashboard shows monitor status and history:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Monitors                                                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ Monitor           │ Last Run    │ Status │ Completion │ Trend     │ │
│  ├────────────────────────────────────────────────────────────────────┤ │
│  │ Daily Regression  │ 2h ago      │ ✓ OK   │ 82.1%      │ ▲ +1.2pp  │ │
│  │ Grounding Check   │ 2h ago      │ ⚠ WARN │ 78.4%      │ ▼ -2.1pp  │ │
│  │ Weekly Full Suite │ 3d ago      │ ✓ OK   │ 79.8%      │ ─         │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  Recent Alerts:                                                          │
│  • Jan 14, 06:12 - grounded_pricing dropped to 76.2% (threshold: 80%)  │
│  • Jan 10, 06:08 - completion_rate recovered to 81.4%                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.6 Collaborative Annotations

**Problem**: Test failures often require human judgement. Was this a real problem or an overly strict criterion?

**Solution**: Allow team members to annotate results:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Turn 4 - Annotation                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Judge verdict: ✗ grounded_pricing                                      │
│                                                                          │
│  Team annotations:                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │ @sarah (PM) - Jan 16, 14:32                                      │   │
│  │ Marked as: FALSE POSITIVE                                         │   │
│  │ "The agent said 'starting from 22k' which is technically correct │   │
│  │ even though it didn't list all prices. Criterion too strict?"    │   │
│  │                                                                    │   │
│  │ @mike (Eng) - Jan 16, 15:01                                       │   │
│  │ Reply: Agree. Should we adjust the criterion to allow 'starting  │   │
│  │ from X' language when X matches the minimum?                      │   │
│  │                                                                    │   │
│  │ @sarah - Jan 16, 15:15                                            │   │
│  │ Created: STUDIO-142 "Refine grounded_pricing criterion"           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  [Add Annotation] [Mark as False Positive] [Create Issue]               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

Annotations feed back into accuracy tracking:

```
Criterion: grounded_pricing
  Judge accuracy: 87.3% (based on 47 annotated cases)
  False positive rate: 9.2%
  False negative rate: 3.5%
```

### 11.7 Prompt Diff & History

**Problem**: Tracking which prompt changes caused which quality changes is manual and error-prone.

**Solution**: First-class prompt versioning with diff view:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Prompt History: Agent System Prompt                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  v2.3 (current) ─────────────────────────────────────────────────────   │
│  │ Commit: abc123 "Add explicit grounding instruction"                  │
│  │ Author: @mike                                                        │
│  │ Experiments: exp_def456 (82.9% completion)                          │
│  │                                                                       │
│  │ Diff vs v2.2:                                                        │
│  │ ┌────────────────────────────────────────────────────────────────┐  │
│  │ │ @@ -45,6 +45,10 @@                                             │  │
│  │ │  When presenting venue options:                                │  │
│  │ │  - List key details clearly                                    │  │
│  │ │  - Include pricing information                                 │  │
│  │ │ +- IMPORTANT: Always cite exact prices from search results     │  │
│  │ │ +- Never approximate or round prices                           │  │
│  │ │ +- Use phrases like "according to our search" when citing      │  │
│  │ │                                                                 │  │
│  │ └────────────────────────────────────────────────────────────────┘  │
│  │                                                                       │
│  v2.2 ───────────────────────────────────────────────────────────────   │
│  │ Commit: 789xyz "Baseline prompt"                                     │
│  │ Experiments: exp_abc123 (76.5% completion)                          │
│  │                                                                       │
│  v2.1 ───────────────────────────────────────────────────────────────   │
│  │ ...                                                                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.8 Custom Dashboard Builder

**Problem**: Different stakeholders need different views of the same data.

**Solution**: Drag-and-drop dashboard builder:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Dashboard: Executive Summary (custom)                    [Edit] [Share]│
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────────────────┐│
│  │  Completion     │ │  Weekly Trend   │ │  Top Issues This Week       ││
│  │    Rate         │ │                 │ │                             ││
│  │   82.9%         │ │    ▄▄▄▄▄█      │ │  1. Price grounding (8)     ││
│  │   ▲ +6.4pp      │ │  ▄▄█████       │ │  2. Slow response (3)       ││
│  │                 │ │  ████████      │ │  3. Wrong venue type (2)    ││
│  └─────────────────┘ └─────────────────┘ └─────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │  Quality Score by Week                                              ││
│  │  ═══════════════════════════════════════════════════════════════   ││
│  │  Jan W1: ████████████████████████████████████████████░░░░░░░ 78%   ││
│  │  Jan W2: ████████████████████████████████████████████████░░░ 83%   ││
│  │  Jan W3: █████████████████████████████████████████████████░░ 85%   ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.9 Integration Ecosystem

**Problem**: The studio needs to fit into existing workflows.

**Solution**: Plugin architecture for integrations:

| Integration | Purpose |
|-------------|---------|
| **GitHub/GitLab** | PR comments with test results, required checks |
| **Slack** | Alerts, daily summaries, Copilot access via slash commands |
| **Jira/Linear** | Auto-create issues from failures, link to test results |
| **Datadog/Grafana** | Export metrics for unified observability |
| **Notion/Confluence** | Sync documentation, export reports |
| **LangSmith/Weights & Biases** | Cross-reference with LLM observability |

Example GitHub integration:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Pull Request #142: Improve grounding in agent prompt                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  rspec-agents-studio bot commented:                                     │
│  ─────────────────────────────────────────────────────────────────────  │
│                                                                          │
│  ## Test Results: exp_def456                                            │
│                                                                          │
│  | Metric | Baseline | This PR | Change |                               │
│  |--------|----------|---------|--------|                               │
│  | Completion | 76.5% | 82.9% | +6.4pp ✅ |                             │
│  | grounded_pricing | 72.0% | 89.0% | +17.0pp ✅ |                      │
│  | friendly | 95.0% | 94.0% | -1.0pp ⚠️ |                               │
│                                                                          │
│  **1 regression detected**: `budget_conscious` now fails                │
│  (was passing in baseline)                                              │
│                                                                          │
│  [View Full Report](https://studio.example.com/exp/def456)              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.10 Self-Improving Criteria

**Problem**: Writing good LLM judge criteria is hard. They're often too strict or too lenient.

**Solution**: Use human annotations to fine-tune criteria:

1. Collect human verdicts on a sample of evaluations
2. Compare to judge verdicts
3. Identify systematic disagreements
4. Suggest criterion refinements or few-shot examples

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Criterion Tuning: grounded_pricing                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Human calibration data: 47 annotated cases                             │
│                                                                          │
│  Current accuracy: 87.3%                                                │
│  ├─ False positives: 9.2% (judged fail, humans say pass)               │
│  └─ False negatives: 3.5% (judged pass, humans say fail)               │
│                                                                          │
│  Analysis of false positives:                                           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │ Pattern: "Starting from X" language                               │   │
│  │ Count: 4/47 (8.5%)                                                │   │
│  │                                                                    │   │
│  │ The judge fails responses that say "starting from €22,500" even  │   │
│  │ when €22,500 is the minimum in tool results. Humans consider     │   │
│  │ this grounded.                                                    │   │
│  │                                                                    │   │
│  │ Suggested addition to criterion:                                  │   │
│  │ "Phrases like 'starting from X' are acceptable when X matches    │   │
│  │ the minimum value in tool results."                               │   │
│  │                                                                    │   │
│  │ [Apply Suggestion] [Add as Edge Case Example] [Dismiss]           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 12. Extension Prioritisation

| Extension | Impact | Effort | Dependencies | Recommended Phase |
|-----------|--------|--------|--------------|-------------------|
| Live Debugging Mode | High | Medium | Phase 1 complete | Phase 2 |
| Failure Clustering | High | Medium | Basic analysis | Phase 3 |
| Production Log Import | High | High | Scenario system | Phase 4+ |
| A/B Experiment Mode | Medium | Medium | Test runner | Phase 3 |
| Continuous Monitoring | High | Medium | Full analysis | Phase 4 |
| Collaborative Annotations | Medium | Low | Result viewer | Phase 2 |
| Prompt Diff & History | Medium | Low | Experiment tracking | Phase 2 |
| Custom Dashboards | Medium | High | Full analysis | Phase 5 |
| Integration Ecosystem | High | High | Core complete | Phase 5 |
| Self-Improving Criteria | Medium | High | Annotations | Phase 5+ |

---

## 13. Open Questions

1. **Multi-tenancy**: Should the studio support multiple teams/projects? What's the isolation model?

2. **CI/CD Integration**: How should Studio integrate with deployment pipelines? Webhook? GitHub Action?

3. **Collaboration**: Should multiple users be able to annotate the same experiment? Real-time or async?

4. **Versioning**: How do we handle scenario set versioning independently from experiment versioning?

5. **Cost Attribution**: Should we track and display LLM costs per experiment? Per scenario?

6. **Self-hosting vs SaaS**: Is this a self-hosted tool or a hosted service? Implications for data privacy.

7. **Offline Mode**: Should the Copilot work offline with a local LLM, or is cloud-only acceptable?
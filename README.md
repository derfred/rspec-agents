# rspec-agents

It's rspec, for agents. Benchmark chatbots with scripted or simulated conversations.

## Installation

Add the gem to your `Gemfile`:

```ruby
group :test do
  gem "rspec-agents"
  gem "anthropic" # used by the default LLM judge / user simulator
end
```

Then create a `spec/agents_helper.rb`:

```ruby
require "rspec/agents"

RSpec::Agents.configure do |config|
  config.agent = MyAgentAdapter     # see "Agent adapters" below
  config.use_anthropic!             # reads ANTHROPIC_API_KEY; pass model: to override
end
```

Requires Ruby >= 3.3.

## Example

Specs tagged `type: :agent` get the DSL. This one lets a simulated user try to reach a goal, then checks the result:

```ruby
RSpec.describe "Venue booking agent", type: :agent do
  criterion :friendly, "The agent's responses are friendly and professional"

  it "helps a planner book a workshop venue" do
    expect_conversation_to do
      use_topic :greeting,           next: :gathering_details
      use_topic :gathering_details,  next: :presenting_results
      use_topic :presenting_results, next: [:gathering_details, :booking]
      use_topic :booking
    end

    user.simulate do
      goal "Find and book a venue for a corporate workshop with 30 attendees in Berlin"
      personality "Busy, to the point, has a budget of 5000 EUR"
      max_turns 8
    end

    expect(conversation).to have_tool_call(:search_venues)
    evaluate(agent).to satisfy(:friendly)            # soft: recorded, doesn't fail the test
    expect(agent).to have_achieved_stated_goal       # hard: fails the test if not met
  end
end
```

You can also script conversations yourself with `user.says "..."` and assert after each turn.

The [Scenario Guide](lib/rspec/agents/doc/scenario_guide.md) covers the rest of the DSL.

## Running specs with `rspec-agents`

The gem ships an `rspec-agents` binary. It runs your specs with conversation-aware terminal output:

```sh
bundle exec rspec-agents spec/agents
```

Pass `-w` to split examples across several worker processes:

```sh
bundle exec rspec-agents -w 4 spec/agents
bundle exec rspec-agents -w 4 --fail-fast --html tmp/report.html spec/agents
```

| Option | Description |
|--------|-------------|
| `-w, --workers COUNT` | Run in parallel with `COUNT` worker processes |
| `--fail-fast` | Stop on first failure (parallel mode) |
| `--ui MODE` | `interactive`, `interleaved` or `quiet` (parallel mode, default: auto-detected) |
| `--json PATH` | Save run data as JSON |
| `--html PATH` | Render an HTML report of all conversations |
| `--upload [URL]` | Stream run data to agents-studio (default `http://localhost:9292`) |
| `--[no-]color` | Force color on/off |

To render an HTML report from saved JSON later:

```sh
bundle exec rspec-agents render tmp/run.json --html tmp/report.html
```

## Agent adapters

rspec-agents never calls your agent directly. It goes through an **adapter**, a subclass of `RSpec::Agents::Agents::Base` that turns the conversation history into a request to your agent and turns the reply into an `AgentResponse`. Your agent can be an HTTP API, an in-process Ruby service or an LLM chain; only the adapter needs to change.

Each example gets a fresh adapter instance. The interface is:

| Method | Required | Purpose |
|--------|----------|---------|
| `self.build(context)` | no | Factory called once per example. `context` holds `:test_name`, `:test_file`, `:test_line`, `:tags` and `:scenario`. |
| `chat(messages, on_tool_call:)` | **yes** | Receives the full history (`role` is `"user"` or `"agent"`, plus `content`). Returns an `AgentResponse`. Call `on_tool_call` for each `ToolCall` so it shows up in reports. |
| `reset!` | no | Clear internal state (for stateful agents). |
| `around(&block)` | no | Wrap the example, e.g. in a DB transaction that is rolled back. |
| `metadata` | no | Return a `Metadata` object for debugging and reporting. |

```ruby
class MyAgentAdapter < RSpec::Agents::Agents::Base
  def chat(messages, on_tool_call: nil)
    reply = MyChatbot.respond(normalize_messages(messages))

    tool_calls = reply.tool_calls.map do |tc|
      RSpec::Agents::ToolCall.new(name: tc.name, arguments: tc.args, result: tc.result)
        .tap { |call| on_tool_call&.call(call) }
    end

    RSpec::Agents::AgentResponse.new(text: reply.text, tool_calls: tool_calls)
  end
end
```

Set the adapter globally with `config.agent = MyAgentAdapter`, or override it per describe block:

```ruby
agent MyOtherAdapter                        # a different adapter class
agent { super(shop: shop) }                 # global adapter, with extra build context
agent { |context| MyAgentAdapter.build(context.merge(locale: :de)) }
```

## License

MIT

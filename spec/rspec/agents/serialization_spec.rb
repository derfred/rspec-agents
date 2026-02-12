require "spec_helper"
require "rspec/agents"
require "tmpdir"

RSpec.describe RSpec::Agents::Serialization do
  let(:now) { Time.now }
  let(:tmp_dir) { Dir.mktmpdir("rspec_agents_test") }

  after { FileUtils.rm_rf(tmp_dir) }

  describe RSpec::Agents::Serialization::ExceptionData do
    describe "#initialize" do
      it "stores class_name, message, and backtrace" do
        data = described_class.new(class_name: "RuntimeError", message: "Something went wrong", backtrace: ["line1", "line2"])
        expect(data.class_name).to eq("RuntimeError")
        expect(data.message).to eq("Something went wrong")
        expect(data.backtrace).to eq(["line1", "line2"])
      end

      it "truncates backtrace to 10 lines" do
        long_backtrace = (1..20).map { |i| "line#{i}" }
        data = described_class.new(class_name: "Error", message: "msg", backtrace: long_backtrace)
        expect(data.backtrace.length).to eq(10)
        expect(data.backtrace.last).to eq("line10")
      end

      it "defaults backtrace to empty array" do
        data = described_class.new(class_name: "Error", message: "msg")
        expect(data.backtrace).to eq([])
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(class_name: "RuntimeError", message: "Error!", backtrace: ["a", "b"])
        hash = original.to_h
        restored = described_class.from_h(hash)

        expect(restored.class_name).to eq(original.class_name)
        expect(restored.message).to eq(original.message)
        expect(restored.backtrace).to eq(original.backtrace)
      end

      it "handles string keys in from_h" do
        hash = { "class_name" => "Error", "message" => "msg", "backtrace" => [] }
        data = described_class.from_h(hash)
        expect(data.class_name).to eq("Error")
      end

      it "returns nil for nil input" do
        expect(described_class.from_h(nil)).to be_nil
      end
    end
  end

  describe RSpec::Agents::Serialization::MessageData do
    describe "#initialize" do
      it "stores role, content, timestamp, source, and metadata" do
        data = described_class.new(role: :user, content: "Hello", timestamp: now, source: :simulator, metadata: { foo: "bar" })
        expect(data.role).to eq("user")
        expect(data.content).to eq("Hello")
        expect(data.timestamp).to eq(now)
        expect(data.source).to eq("simulator")
        expect(data.metadata).to be_a(RSpec::Agents::Metadata)
        expect(data.metadata[:foo]).to eq("bar")
      end

      it "converts role to string" do
        data = described_class.new(role: :agent, content: "Hi", timestamp: now)
        expect(data.role).to eq("agent")
      end

      it "wraps metadata in Metadata object" do
        data = described_class.new(role: :user, content: "Hi", timestamp: now, metadata: { key: "value" })
        expect(data.metadata).to be_a(RSpec::Agents::Metadata)
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes timestamp as ISO 8601 with milliseconds" do
        data = described_class.new(role: :user, content: "Hi", timestamp: now)
        hash = data.to_h
        expect(hash[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/)
      end

      it "deserializes correctly" do
        original = described_class.new(role: :user, content: "Hello", timestamp: now, source: :script, metadata: { x: 1 })
        restored = described_class.from_h(original.to_h)

        expect(restored.role).to eq(original.role)
        expect(restored.content).to eq(original.content)
        expect(restored.timestamp).to be_within(0.001).of(original.timestamp)
        expect(restored.source).to eq(original.source)
      end
    end
  end

  describe RSpec::Agents::Serialization::ToolCallData do
    describe "#initialize" do
      it "stores name, arguments, result, error, timestamp, and metadata" do
        data = described_class.new(name: :search, arguments: { q: "test" }, timestamp: now, result: "found", error: nil)
        expect(data.name).to eq("search")
        expect(data.arguments).to eq({ q: "test" })
        expect(data.result).to eq("found")
        expect(data.error).to be_nil
      end

      it "converts name to string" do
        data = described_class.new(name: :my_tool, arguments: {}, timestamp: now)
        expect(data.name).to eq("my_tool")
      end

      it "defaults arguments to empty hash" do
        data = described_class.new(name: "tool", arguments: nil, timestamp: now)
        expect(data.arguments).to eq({})
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(name: :search, arguments: { query: "test" }, timestamp: now, result: "ok", error: nil)
        restored = described_class.from_h(original.to_h)

        expect(restored.name).to eq(original.name)
        expect(restored.arguments).to eq(original.arguments)
        expect(restored.result).to eq(original.result)
      end
    end
  end

  describe RSpec::Agents::Serialization::EvaluationData do
    describe "#initialize" do
      it "stores all fields" do
        data = described_class.new(name: "grounded", description: "Check grounding", passed: true, timestamp: now, reasoning: "Good")
        expect(data.name).to eq("grounded")
        expect(data.description).to eq("Check grounding")
        expect(data.passed).to be true
        expect(data.reasoning).to eq("Good")
      end

      it "stores mode and type as symbols" do
        data = described_class.new(
          name:            "satisfy(friendly)",
          description:     "satisfy(friendly)",
          passed:          true,
          timestamp:       now,
          mode:            :soft,
          type:            :quality,
          failure_message: nil,
          metadata:        { criteria: ["friendly"] }
        )
        expect(data.mode).to eq(:soft)
        expect(data.type).to eq(:quality)
        expect(data.failure_message).to be_nil
        expect(data.metadata[:criteria]).to eq(["friendly"])
      end

      it "converts string mode/type to symbols" do
        data = described_class.new(
          name:            "test",
          description:     "test",
          passed:          false,
          timestamp:       now,
          mode:            "hard",
          type:            "tool_call",
          failure_message: "Expected tool call"
        )
        expect(data.mode).to eq(:hard)
        expect(data.type).to eq(:tool_call)
        expect(data.failure_message).to eq("Expected tool call")
      end
    end

    describe "#soft? and #hard?" do
      it "returns true for soft evaluations" do
        data = described_class.new(name: "test", description: "test", passed: true, timestamp: now, mode: :soft)
        expect(data.soft?).to be true
        expect(data.hard?).to be false
      end

      it "returns true for hard expectations" do
        data = described_class.new(name: "test", description: "test", passed: true, timestamp: now, mode: :hard)
        expect(data.soft?).to be false
        expect(data.hard?).to be true
      end

      it "returns false for both when mode is nil" do
        data = described_class.new(name: "test", description: "test", passed: true, timestamp: now)
        expect(data.soft?).to be false
        expect(data.hard?).to be false
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(name: "test", description: "desc", passed: false, timestamp: now, reasoning: "Failed")
        restored = described_class.from_h(original.to_h)

        expect(restored.name).to eq(original.name)
        expect(restored.passed).to eq(original.passed)
        expect(restored.reasoning).to eq(original.reasoning)
      end

      it "serializes and deserializes mode/type/failure_message correctly" do
        original = described_class.new(
          name:            "call_tool(:search)",
          description:     "call_tool(:search)",
          passed:          false,
          timestamp:       now,
          reasoning:       nil,
          mode:            :hard,
          type:            :tool_call,
          failure_message: "Expected call to :search but got :lookup",
          metadata:        { tool_name: "search", turn_number: 2 }
        )
        restored = described_class.from_h(original.to_h)

        expect(restored.mode).to eq(:hard)
        expect(restored.type).to eq(:tool_call)
        expect(restored.failure_message).to eq("Expected call to :search but got :lookup")
        expect(restored.hard?).to be true
        expect(restored.metadata[:tool_name]).to eq("search")
      end
    end
  end

  describe RSpec::Agents::Serialization::ScenarioData do
    let(:scenario_hash) do
      {
        id:          "corporate_workshop",
        name:        "Corporate workshop in Stuttgart",
        goal:        "Find a venue for 50 people",
        context:     ["Works at Acme GmbH"],
        personality: "Professional"
      }
    end

    describe "#initialize" do
      it "stores all fields" do
        data = described_class.new(
          id:           "scenario_abc123",
          name:         "Test scenario",
          goal:         "Complete the task",
          personality:  "Friendly",
          context:      ["User is new"],
          verification: { check: "done" },
          data:         scenario_hash
        )
        expect(data.id).to eq("scenario_abc123")
        expect(data.name).to eq("Test scenario")
        expect(data.goal).to eq("Complete the task")
        expect(data.personality).to eq("Friendly")
        expect(data.context).to eq(["User is new"])
        expect(data.verification).to eq({ check: "done" })
        expect(data.data).to eq(scenario_hash)
      end

      it "defaults optional fields to nil" do
        data = described_class.new(id: "s1", name: "test", goal: "test goal")
        expect(data.personality).to be_nil
        expect(data.context).to be_nil
        expect(data.verification).to be_nil
        expect(data.data).to eq({})
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(
          id:           "scenario_abc123",
          name:         "Test scenario",
          goal:         "Complete the task",
          personality:  "Friendly",
          context:      ["User is new"],
          verification: { check: "done" },
          data:         scenario_hash
        )
        restored = described_class.from_h(original.to_h)

        expect(restored.id).to eq(original.id)
        expect(restored.name).to eq(original.name)
        expect(restored.goal).to eq(original.goal)
        expect(restored.personality).to eq(original.personality)
        expect(restored.context).to eq(original.context)
        expect(restored.verification).to eq(original.verification)
      end

      it "handles string keys in from_h" do
        hash = { "id" => "s1", "name" => "test", "goal" => "test goal" }
        data = described_class.from_h(hash)
        expect(data.id).to eq("s1")
        expect(data.name).to eq("test")
      end

      it "returns nil for nil input" do
        expect(described_class.from_h(nil)).to be_nil
      end
    end

    describe ".from_scenario" do
      it "creates ScenarioData from a Scenario object" do
        scenario = RSpec::Agents::Scenario.new(scenario_hash)
        data = described_class.from_scenario(scenario)

        expect(data.id).to eq(scenario.identifier)
        expect(data.name).to eq("Corporate workshop in Stuttgart")
        expect(data.goal).to eq("Find a venue for 50 people")
        expect(data.personality).to eq("Professional")
        expect(data.context).to eq(["Works at Acme GmbH"])
      end

      it "returns nil for nil scenario" do
        expect(described_class.from_scenario(nil)).to be_nil
      end
    end
  end

  describe RSpec::Agents::Serialization::TurnData do
    let(:user_msg) { RSpec::Agents::Serialization::MessageData.new(role: :user, content: "Hi", timestamp: now) }
    let(:agent_msg) { RSpec::Agents::Serialization::MessageData.new(role: :agent, content: "Hello", timestamp: now) }
    let(:tool_call) { RSpec::Agents::Serialization::ToolCallData.new(name: :search, arguments: {}, timestamp: now) }

    describe "#initialize" do
      it "stores number, user_message, and optional fields" do
        turn = described_class.new(number: 1, user_message: user_msg, agent_response: agent_msg, tool_calls: [tool_call], topic: :greeting)
        expect(turn.number).to eq(1)
        expect(turn.user_message).to eq(user_msg)
        expect(turn.agent_response).to eq(agent_msg)
        expect(turn.tool_calls).to eq([tool_call])
        expect(turn.topic).to eq("greeting")
      end

      it "defaults tool_calls to empty array" do
        turn = described_class.new(number: 1, user_message: user_msg)
        expect(turn.tool_calls).to eq([])
      end
    end

    describe "mutability" do
      it "allows setting agent_response after creation" do
        turn = described_class.new(number: 1, user_message: user_msg)
        turn.agent_response = agent_msg
        expect(turn.agent_response).to eq(agent_msg)
      end

      it "allows setting tool_calls after creation" do
        turn = described_class.new(number: 1, user_message: user_msg)
        turn.tool_calls = [tool_call]
        expect(turn.tool_calls).to eq([tool_call])
      end

      it "allows setting topic after creation" do
        turn = described_class.new(number: 1, user_message: user_msg)
        turn.topic = :presenting
        expect(turn.topic).to eq("presenting")
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(number: 1, user_message: user_msg, agent_response: agent_msg, tool_calls: [tool_call], topic: :test)
        restored = described_class.from_h(original.to_h)

        expect(restored.number).to eq(original.number)
        expect(restored.user_message.content).to eq(original.user_message.content)
        expect(restored.agent_response.content).to eq(original.agent_response.content)
        expect(restored.tool_calls.length).to eq(1)
        expect(restored.topic).to eq(original.topic)
      end
    end
  end

  describe RSpec::Agents::Serialization::ConversationData do
    let(:user_msg) { RSpec::Agents::Serialization::MessageData.new(role: :user, content: "Hi", timestamp: now) }
    let(:turn) { RSpec::Agents::Serialization::TurnData.new(number: 1, user_message: user_msg) }

    describe "#initialize" do
      it "stores started_at and optional fields" do
        conv = described_class.new(started_at: now, ended_at: now + 60, final_topic: :done)
        expect(conv.started_at).to eq(now)
        expect(conv.ended_at).to eq(now + 60)
        expect(conv.final_topic).to eq("done")
      end

      it "defaults turns to empty array" do
        conv = described_class.new(started_at: now)
        expect(conv.turns).to eq([])
      end
    end

    describe "#add_turn" do
      it "adds turn to turns array" do
        conv = described_class.new(started_at: now)
        conv.add_turn(turn)
        expect(conv.turns).to eq([turn])
      end
    end

    describe "#current_turn" do
      it "returns the last turn" do
        conv = described_class.new(started_at: now, turns: [turn])
        expect(conv.current_turn).to eq(turn)
      end

      it "returns nil for empty turns" do
        conv = described_class.new(started_at: now)
        expect(conv.current_turn).to be_nil
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(started_at: now, ended_at: now + 60, turns: [turn], final_topic: :greeting)
        restored = described_class.from_h(original.to_h)

        expect(restored.started_at).to be_within(0.001).of(original.started_at)
        expect(restored.ended_at).to be_within(0.001).of(original.ended_at)
        expect(restored.turns.length).to eq(1)
        expect(restored.final_topic).to eq(original.final_topic)
      end
    end
  end

  describe RSpec::Agents::Serialization::ExampleData do
    let(:conversation) { RSpec::Agents::Serialization::ConversationData.new(started_at: now) }
    let(:exception) { RSpec::Agents::Serialization::ExceptionData.new(class_name: "Error", message: "Failed") }

    describe "#initialize" do
      it "stores all fields" do
        data = described_class.new(
          id: "abc123", file: "spec/test_spec.rb", description: "does something",
          location: "spec/test_spec.rb:42", started_at: now, status: :running
        )
        expect(data.id).to eq("abc123")
        expect(data.file).to eq("spec/test_spec.rb")
        expect(data.description).to eq("does something")
        expect(data.location).to eq("spec/test_spec.rb:42")
        expect(data.status).to eq(:running)
      end

      it "defaults status to :pending" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now)
        expect(data.status).to eq(:pending)
      end

      it "converts status to symbol" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now, status: "passed")
        expect(data.status).to eq(:passed)
      end
    end

    describe "mutability" do
      it "allows setting status" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now)
        data.status = :passed
        expect(data.status).to eq(:passed)
      end

      it "allows setting finished_at and duration_ms" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now)
        data.finished_at = now + 1
        data.duration_ms = 1000
        expect(data.finished_at).to eq(now + 1)
        expect(data.duration_ms).to eq(1000)
      end

      it "allows setting conversation and exception" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now)
        data.conversation = conversation
        data.exception = exception
        expect(data.conversation).to eq(conversation)
        expect(data.exception).to eq(exception)
      end
    end

    describe "#add_evaluation" do
      it "adds evaluation to evaluations array" do
        data = described_class.new(id: "x", file: "f", description: "d", location: "l", started_at: now)
        eval_data = RSpec::Agents::Serialization::EvaluationData.new(name: "test", description: "d", passed: true, timestamp: now)
        data.add_evaluation(eval_data)
        expect(data.evaluations).to eq([eval_data])
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(
          id: "abc", file: "spec/test.rb", description: "test", location: "spec/test.rb:1",
          started_at: now, status: :passed, finished_at: now + 1, duration_ms: 1000,
          conversation: conversation, exception: exception
        )
        restored = described_class.from_h(original.to_h)

        expect(restored.id).to eq(original.id)
        expect(restored.status).to eq(original.status)
        expect(restored.duration_ms).to eq(original.duration_ms)
        expect(restored.conversation).to be_a(RSpec::Agents::Serialization::ConversationData)
        expect(restored.exception.class_name).to eq("Error")
      end
    end
  end

  describe RSpec::Agents::Serialization::RunData do
    let(:example_data) do
      RSpec::Agents::Serialization::ExampleData.new(
        id: "ex1", file: "spec/test.rb", description: "test", location: "spec/test.rb:1",
        started_at: now, status: :passed, duration_ms: 100
      )
    end

    describe "#initialize" do
      it "stores run_id, started_at, seed, examples, and scenarios" do
        data = described_class.new(run_id: "run-123", started_at: now, seed: 12345)
        expect(data.run_id).to eq("run-123")
        expect(data.started_at).to eq(now)
        expect(data.seed).to eq(12345)
        expect(data.examples).to eq({})
        expect(data.scenarios).to eq({})
      end
    end

    describe "#add_example" do
      it "adds example keyed by id" do
        data = described_class.new(run_id: "run", started_at: now)
        data.add_example(example_data)
        expect(data.examples["ex1"]).to eq(example_data)
      end
    end

    describe "#example" do
      it "retrieves example by id" do
        data = described_class.new(run_id: "run", started_at: now, examples: { "ex1" => example_data })
        expect(data.example("ex1")).to eq(example_data)
      end

      it "returns nil for missing id" do
        data = described_class.new(run_id: "run", started_at: now)
        expect(data.example("missing")).to be_nil
      end
    end

    describe "#register_scenario" do
      it "adds scenario to scenarios hash" do
        data = described_class.new(run_id: "run", started_at: now)
        scenario_data = RSpec::Agents::Serialization::ScenarioData.new(id: "scenario_abc123", name: "Test", goal: "Do something")
        data.register_scenario(scenario_data)
        expect(data.scenarios["scenario_abc123"]).to eq(scenario_data)
      end

      it "returns the scenario ID" do
        data = described_class.new(run_id: "run", started_at: now)
        scenario_data = RSpec::Agents::Serialization::ScenarioData.new(id: "scenario_abc123", name: "Test", goal: "Do something")
        result = data.register_scenario(scenario_data)
        expect(result).to eq("scenario_abc123")
      end

      it "does not duplicate existing scenarios" do
        data = described_class.new(run_id: "run", started_at: now)
        scenario_data = RSpec::Agents::Serialization::ScenarioData.new(id: "scenario_abc123", name: "Test", goal: "Do something")
        data.register_scenario(scenario_data)
        data.register_scenario(scenario_data)
        expect(data.scenarios.keys).to eq(["scenario_abc123"])
      end

      it "returns nil for nil input" do
        data = described_class.new(run_id: "run", started_at: now)
        expect(data.register_scenario(nil)).to be_nil
      end
    end

    describe "#scenario" do
      it "retrieves scenario by id" do
        scenario_data = RSpec::Agents::Serialization::ScenarioData.new(id: "scenario_abc123", name: "Test", goal: "Do something")
        data = described_class.new(run_id: "run", started_at: now, scenarios: { "scenario_abc123" => scenario_data })
        expect(data.scenario("scenario_abc123")).to eq(scenario_data)
      end

      it "returns nil for missing id" do
        data = described_class.new(run_id: "run", started_at: now)
        expect(data.scenario("missing")).to be_nil
      end
    end

    describe "#summary" do
      it "computes summary statistics" do
        passed = RSpec::Agents::Serialization::ExampleData.new(id: "p", file: "f", description: "d", location: "l", started_at: now, status: :passed, duration_ms: 100)
        failed = RSpec::Agents::Serialization::ExampleData.new(id: "f", file: "f", description: "d", location: "l", started_at: now, status: :failed, duration_ms: 200)
        pending = RSpec::Agents::Serialization::ExampleData.new(id: "pe", file: "f", description: "d", location: "l", started_at: now, status: :pending, duration_ms: 0)

        data = described_class.new(run_id: "run", started_at: now, examples: { "p" => passed, "f" => failed, "pe" => pending })
        summary = data.summary

        expect(summary.example_count).to eq(3)
        expect(summary.passed_count).to eq(1)
        expect(summary.failed_count).to eq(1)
        expect(summary.pending_count).to eq(1)
        expect(summary.total_duration_ms).to eq(300)
      end
    end

    describe "#to_h / .from_h round-trip" do
      it "serializes and deserializes correctly" do
        original = described_class.new(run_id: "run-123", started_at: now, finished_at: now + 60, seed: 42, examples: { "ex1" => example_data })
        restored = described_class.from_h(original.to_h)

        expect(restored.run_id).to eq(original.run_id)
        expect(restored.seed).to eq(original.seed)
        expect(restored.examples.keys).to eq(["ex1"])
        expect(restored.example("ex1").description).to eq("test")
      end

      it "serializes and deserializes scenarios correctly" do
        scenario_data = RSpec::Agents::Serialization::ScenarioData.new(
          id:          "scenario_abc123",
          name:        "Corporate workshop",
          goal:        "Find a venue",
          personality: "Professional"
        )
        example_with_scenario = RSpec::Agents::Serialization::ExampleData.new(
          id: "ex1", file: "spec/test.rb", description: "test", location: "spec/test.rb:1",
          started_at: now, status: :passed, duration_ms: 100, scenario_id: "scenario_abc123"
        )
        original = described_class.new(
          run_id:      "run-123",
          started_at:  now,
          finished_at: now + 60,
          seed:        42,
          scenarios:   { "scenario_abc123" => scenario_data },
          examples:    { "ex1" => example_with_scenario }
        )
        restored = described_class.from_h(original.to_h)

        expect(restored.scenarios.keys).to eq(["scenario_abc123"])
        expect(restored.scenario("scenario_abc123")).to be_a(RSpec::Agents::Serialization::ScenarioData)
        expect(restored.scenario("scenario_abc123").name).to eq("Corporate workshop")
        expect(restored.scenario("scenario_abc123").goal).to eq("Find a venue")
        expect(restored.example("ex1").scenario_id).to eq("scenario_abc123")
      end
    end
  end

  describe RSpec::Agents::Serialization::SummaryStats do
    describe "#to_h" do
      it "serializes all fields" do
        stats = described_class.new(example_count: 10, passed_count: 8, failed_count: 1, pending_count: 1, total_duration_ms: 5000)
        hash = stats.to_h

        expect(hash[:example_count]).to eq(10)
        expect(hash[:passed_count]).to eq(8)
        expect(hash[:failed_count]).to eq(1)
        expect(hash[:pending_count]).to eq(1)
        expect(hash[:total_duration_ms]).to eq(5000)
      end
    end
  end

  describe RSpec::Agents::Serialization::JsonFile do
    let(:run_data) do
      example = RSpec::Agents::Serialization::ExampleData.new(
        id: "ex1", file: "spec/test.rb", description: "test", location: "spec/test.rb:1",
        started_at: now, status: :passed, duration_ms: 100
      )
      RSpec::Agents::Serialization::RunData.new(run_id: "test-run", started_at: now, seed: 123, examples: { "ex1" => example })
    end

    describe ".write and .read" do
      it "writes and reads RunData to/from JSON file" do
        path = File.join(tmp_dir, "test_run_data.json")
        FileUtils.rm_f(path)

        described_class.write(path, run_data)
        expect(File.exist?(path)).to be true

        restored = described_class.read(path)
        expect(restored.run_id).to eq("test-run")
        expect(restored.seed).to eq(123)
        expect(restored.example("ex1").status).to eq(:passed)
      ensure
        FileUtils.rm_f(path)
      end

      it "creates parent directories if needed" do
        path = File.join(tmp_dir, "nested/dir/test_run.json")
        FileUtils.rm_rf(File.join(tmp_dir, "nested"))

        described_class.write(path, run_data)
        expect(File.exist?(path)).to be true
      ensure
        FileUtils.rm_rf(File.join(tmp_dir, "nested"))
      end
    end
  end

  describe RSpec::Agents::Serialization::RunDataBuilder do
    let(:event_bus) { RSpec::Agents::EventBus.instance }
    let(:builder) { described_class.new(event_bus: event_bus) }

    before { event_bus.clear! }

    def example_started_event(example_id:, description:, full_description:, location:, time:, scenario: nil)
      RSpec::Agents::Events::ExampleStarted.new(
        example_id:       example_id,
        stable_id:        "stable_#{example_id}",
        canonical_path:   "TestClass::#{description}",
        description:      description,
        full_description: full_description,
        location:         location,
        time:             time,
        scenario:         scenario
      )
    end

    def example_passed_event(example_id:, description:, full_description:, duration:, time:)
      RSpec::Agents::Events::ExamplePassed.new(
        example_id:       example_id,
        stable_id:        "stable_#{example_id}",
        description:      description,
        full_description: full_description,
        duration:         duration,
        time:             time
      )
    end

    def example_failed_event(example_id:, description:, full_description:, location:, duration:, message:, backtrace:, time:)
      RSpec::Agents::Events::ExampleFailed.new(
        example_id:       example_id,
        stable_id:        "stable_#{example_id}",
        description:      description,
        full_description: full_description,
        location:         location,
        duration:         duration,
        message:          message,
        backtrace:        backtrace,
        time:             time
      )
    end

    describe "#on_suite_started" do
      it "creates a RunData with seed" do
        event = RSpec::Agents::Events::SuiteStarted.new(example_count: 5, load_time: 0.5, seed: 12345, time: now)
        builder.on_suite_started(event)

        expect(builder.run_data).to be_a(RSpec::Agents::Serialization::RunData)
        expect(builder.run_data.seed).to eq(12345)
        expect(builder.run_data.started_at).to eq(now)
      end
    end

    describe "#on_suite_stopped" do
      it "sets finished_at on run_data" do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        finish_time = now + 60

        builder.on_suite_stopped(RSpec::Agents::Events::SuiteStopped.new(time: finish_time))

        expect(builder.run_data.finished_at).to eq(finish_time)
      end
    end

    describe "#on_example_started" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
      end

      it "creates ExampleData with conversation" do
        event = example_started_event(
          example_id: "ex1", description: "does something", full_description: "MyClass does something",
          location: "spec/my_spec.rb:10", scenario: nil, time: now
        )
        builder.on_example_started(event)

        example = builder.run_data.example("ex1")
        expect(example).to be_a(RSpec::Agents::Serialization::ExampleData)
        expect(example.description).to eq("does something")
        expect(example.status).to eq(:running)
        expect(example.conversation).to be_a(RSpec::Agents::Serialization::ConversationData)
      end

      it "registers scenario and links to example when scenario is present" do
        scenario = RSpec::Agents::Scenario.new({
          name:        "Corporate workshop",
          goal:        "Find a venue for 50 people",
          personality: "Professional"
        })
        event = example_started_event(
          example_id: "ex1", description: "handles corporate workshop", full_description: "Agent handles corporate workshop",
          location: "spec/my_spec.rb:10", scenario: scenario, time: now
        )
        builder.on_example_started(event)

        # Scenario is registered in run_data
        expect(builder.run_data.scenarios.keys).to eq([scenario.identifier])
        scenario_data = builder.run_data.scenario(scenario.identifier)
        expect(scenario_data).to be_a(RSpec::Agents::Serialization::ScenarioData)
        expect(scenario_data.name).to eq("Corporate workshop")
        expect(scenario_data.goal).to eq("Find a venue for 50 people")

        # Example references scenario
        example = builder.run_data.example("ex1")
        expect(example.scenario_id).to eq(scenario.identifier)
      end

      it "does not duplicate scenarios when same scenario is used in multiple examples" do
        scenario = RSpec::Agents::Scenario.new({
          name: "Shared scenario",
          goal: "Do something"
        })
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test 1", full_description: "test 1",
          location: "spec/test.rb:1", scenario: scenario, time: now
        ))
        builder.on_example_started(example_started_event(
          example_id: "ex2", description: "test 2", full_description: "test 2",
          location: "spec/test.rb:10", scenario: scenario, time: now
        ))

        # Only one scenario registered
        expect(builder.run_data.scenarios.keys).to eq([scenario.identifier])

        # Both examples reference the same scenario
        expect(builder.run_data.example("ex1").scenario_id).to eq(scenario.identifier)
        expect(builder.run_data.example("ex2").scenario_id).to eq(scenario.identifier)
      end

      it "handles examples without scenarios" do
        event = example_started_event(
          example_id: "ex1", description: "does something", full_description: "MyClass does something",
          location: "spec/my_spec.rb:10", scenario: nil, time: now
        )
        builder.on_example_started(event)

        expect(builder.run_data.scenarios).to be_empty
        expect(builder.run_data.example("ex1").scenario_id).to be_nil
      end
    end

    describe "#on_example_passed" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", scenario: nil, time: now
        ))
      end

      it "sets status to :passed and records duration" do
        event = example_passed_event(
          example_id: "ex1", description: "test", full_description: "test",
          duration: 0.5, time: now + 1
        )
        builder.on_example_passed(event)

        example = builder.run_data.example("ex1")
        expect(example.status).to eq(:passed)
        expect(example.duration_ms).to eq(500)
        expect(example.finished_at).to eq(now + 1)
      end
    end

    describe "#on_example_failed" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", scenario: nil, time: now
        ))
      end

      it "sets status to :failed and records exception" do
        event = example_failed_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", duration: 0.3, message: "Expected true got false", backtrace: ["line1", "line2"], time: now + 1
        )
        builder.on_example_failed(event)

        example = builder.run_data.example("ex1")
        expect(example.status).to eq(:failed)
        expect(example.exception).to be_a(RSpec::Agents::Serialization::ExceptionData)
        expect(example.exception.message).to eq("Expected true got false")
      end
    end

    describe "#on_user_message and #on_agent_response" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", scenario: nil, time: now
        ))
      end

      it "builds conversation turns from messages" do
        # User sends message
        builder.on_user_message(RSpec::Agents::Events::UserMessage.new(
          example_id: "ex1", turn_number: 1, text: "Hello", source: "simulator", time: now
        ))

        # Agent responds
        builder.on_agent_response(RSpec::Agents::Events::AgentResponse.new(
          example_id: "ex1", turn_number: 1, text: "Hi there!",
          tool_calls: [{ name: "greet", arguments: { name: "user" }, result: "greeted" }],
          metadata: {}, time: now + 1
        ))

        # Example finishes (which finalizes the turn)
        builder.on_example_passed(example_passed_event(
          example_id: "ex1", description: "test", full_description: "test",
          duration: 0.5, time: now + 2
        ))

        example = builder.run_data.example("ex1")
        expect(example.conversation.turns.size).to eq(1)

        turn = example.conversation.turns.first
        expect(turn.number).to eq(1)
        expect(turn.user_message.content).to eq("Hello")
        expect(turn.agent_response.content).to eq("Hi there!")
        expect(turn.tool_calls.size).to eq(1)
        expect(turn.tool_calls.first.name).to eq("greet")
      end
    end

    describe "#on_topic_changed" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", scenario: nil, time: now
        ))
        builder.on_user_message(RSpec::Agents::Events::UserMessage.new(
          example_id: "ex1", turn_number: 1, text: "Hello", source: "simulator", time: now
        ))
      end

      it "sets topic on current turn" do
        builder.on_topic_changed(RSpec::Agents::Events::TopicChanged.new(
          example_id: "ex1", turn_number: 1, from_topic: nil, to_topic: "greeting", trigger: "agent", time: now
        ))

        builder.on_example_passed(example_passed_event(
          example_id: "ex1", description: "test", full_description: "test",
          duration: 0.5, time: now + 1
        ))

        turn = builder.run_data.example("ex1").conversation.turns.first
        expect(turn.topic).to eq("greeting")
      end
    end

    describe "#on_evaluation_recorded" do
      before do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 1, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "test",
          location: "spec/test.rb:1", time: now
        ))
      end

      it "records soft evaluations" do
        event = RSpec::Agents::Events::EvaluationRecorded.new(
          example_id:      "ex1",
          turn_number:     1,
          mode:            :soft,
          type:            :quality,
          description:     "satisfy(friendly)",
          passed:          true,
          failure_message: nil,
          metadata:        { criteria: ["friendly"] },
          time:            now
        )
        builder.on_evaluation_recorded(event)

        example = builder.run_data.example("ex1")
        expect(example.evaluations.size).to eq(1)

        evaluation = example.evaluations.first
        expect(evaluation.name).to eq("satisfy(friendly)")
        expect(evaluation.mode).to eq(:soft)
        expect(evaluation.type).to eq(:quality)
        expect(evaluation.passed).to be true
        expect(evaluation.soft?).to be true
      end

      it "records hard expectations" do
        event = RSpec::Agents::Events::EvaluationRecorded.new(
          example_id:      "ex1",
          turn_number:     2,
          mode:            :hard,
          type:            :tool_call,
          description:     "call_tool(:search)",
          passed:          false,
          failure_message: "Expected call to :search but no tool calls were made",
          metadata:        { tool_name: "search" },
          time:            now
        )
        builder.on_evaluation_recorded(event)

        example = builder.run_data.example("ex1")
        evaluation = example.evaluations.first
        expect(evaluation.mode).to eq(:hard)
        expect(evaluation.type).to eq(:tool_call)
        expect(evaluation.passed).to be false
        expect(evaluation.failure_message).to eq("Expected call to :search but no tool calls were made")
        expect(evaluation.hard?).to be true
      end

      it "records multiple evaluations" do
        builder.on_evaluation_recorded(RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "ex1", turn_number: 1, mode: :soft, type: :quality,
          description: "satisfy(friendly)", passed: true, failure_message: nil, metadata: {}, time: now
        ))
        builder.on_evaluation_recorded(RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "ex1", turn_number: 1, mode: :soft, type: :grounding,
          description: "be_grounded_in(:pricing)", passed: false, failure_message: "Claim not grounded", metadata: {}, time: now
        ))
        builder.on_evaluation_recorded(RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "ex1", turn_number: 2, mode: :hard, type: :tool_call,
          description: "call_tool(:book)", passed: true, failure_message: nil, metadata: {}, time: now
        ))

        example = builder.run_data.example("ex1")
        expect(example.evaluations.size).to eq(3)

        soft_evals = example.evaluations.select(&:soft?)
        hard_evals = example.evaluations.select(&:hard?)
        expect(soft_evals.size).to eq(2)
        expect(hard_evals.size).to eq(1)
      end

      it "ignores evaluations for unknown examples" do
        event = RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "unknown", turn_number: 1, mode: :soft, type: :quality,
          description: "test", passed: true, failure_message: nil, metadata: {}, time: now
        )
        expect { builder.on_evaluation_recorded(event) }.not_to raise_error
      end
    end

    describe "full round-trip serialization" do
      it "serializes and deserializes a complete run" do
        # Build a complete run
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 42, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "MyClass test",
          location: "spec/test.rb:1", scenario: nil, time: now
        ))
        builder.on_user_message(RSpec::Agents::Events::UserMessage.new(
          example_id: "ex1", turn_number: 1, text: "Hello", source: "simulator", time: now
        ))
        builder.on_agent_response(RSpec::Agents::Events::AgentResponse.new(
          example_id: "ex1", turn_number: 1, text: "Hi!",
          tool_calls: [], metadata: {}, time: now + 1
        ))
        builder.on_example_passed(example_passed_event(
          example_id: "ex1", description: "test", full_description: "MyClass test",
          duration: 0.5, time: now + 2
        ))
        builder.on_suite_stopped(RSpec::Agents::Events::SuiteStopped.new(time: now + 3))

        # Serialize and deserialize
        path = File.join(tmp_dir, "builder_roundtrip.json")
        RSpec::Agents::Serialization::JsonFile.write(path, builder.run_data)
        restored = RSpec::Agents::Serialization::JsonFile.read(path)

        expect(restored.seed).to eq(42)
        expect(restored.examples.size).to eq(1)
        expect(restored.example("ex1").status).to eq(:passed)
        expect(restored.example("ex1").conversation.turns.size).to eq(1)
        expect(restored.example("ex1").conversation.turns.first.user_message.content).to eq("Hello")
      end

      it "serializes and deserializes evaluations with mode/type" do
        builder.on_suite_started(RSpec::Agents::Events::SuiteStarted.new(example_count: 1, load_time: 0.1, seed: 42, time: now))
        builder.on_example_started(example_started_event(
          example_id: "ex1", description: "test", full_description: "MyClass test",
          location: "spec/test.rb:1", time: now
        ))
        builder.on_evaluation_recorded(RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "ex1", turn_number: 1, mode: :soft, type: :quality,
          description: "satisfy(friendly)", passed: true, failure_message: nil,
          metadata: { criteria: ["friendly"], turn_number: 1 }, time: now
        ))
        builder.on_evaluation_recorded(RSpec::Agents::Events::EvaluationRecorded.new(
          example_id: "ex1", turn_number: 2, mode: :hard, type: :tool_call,
          description: "call_tool(:book)", passed: false, failure_message: "No tool called",
          metadata: { tool_name: "book" }, time: now + 1
        ))
        builder.on_example_failed(example_failed_event(
          example_id: "ex1", description: "test", full_description: "MyClass test",
          location: "spec/my_class_spec.rb:10", duration: 0.5, message: "No tool called", backtrace: [], time: now + 2
        ))
        builder.on_suite_stopped(RSpec::Agents::Events::SuiteStopped.new(time: now + 3))

        path = File.join(tmp_dir, "evaluation_roundtrip.json")
        RSpec::Agents::Serialization::JsonFile.write(path, builder.run_data)
        restored = RSpec::Agents::Serialization::JsonFile.read(path)

        example = restored.example("ex1")
        expect(example.evaluations.size).to eq(2)

        soft_eval = example.evaluations.find(&:soft?)
        expect(soft_eval.description).to eq("satisfy(friendly)")
        expect(soft_eval.type).to eq(:quality)
        expect(soft_eval.passed).to be true

        hard_eval = example.evaluations.find(&:hard?)
        expect(hard_eval.description).to eq("call_tool(:book)")
        expect(hard_eval.type).to eq(:tool_call)
        expect(hard_eval.passed).to be false
        expect(hard_eval.failure_message).to eq("No tool called")
      end
    end
  end
end

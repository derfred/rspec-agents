require "spec_helper"
require "tmpdir"
require "rspec/agents/serialization/test_suite_renderer"

RSpec.describe RSpec::Agents::Serialization::TestSuiteRenderer do
  let(:now) { Time.now }
  let(:tmp_dir) { File.join(Dir.tmpdir, "test_html_renderer") }

  before do
    FileUtils.mkdir_p(tmp_dir)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  def build_run_data(status: :passed, with_traces: true, with_tool_calls: true, with_evaluations: true)
    trace_metadata = if with_traces
                       {
                         traces: [{
                           "model"      => "gpt-4",
                           "timestamps" => {
                             "started_at"  => now.iso8601,
                             "finished_at" => (now + 0.5).iso8601
                           },
                           "metrics"    => { "prompt_tokens" => 100, "completion_tokens" => 50 },
                           "tool_calls" => with_tool_calls ? [{ "name" => "weather_lookup", "arguments" => { "city" => "SF" } }] : []
                         }]
                       }
                     else
                       {}
                     end

    user_msg = RSpec::Agents::Serialization::MessageData.new(
      role: :user, content: "What is the weather?", timestamp: now,
      metadata: { source: "simulator" }
    )
    agent_msg = RSpec::Agents::Serialization::MessageData.new(
      role: :agent, content: "The weather is sunny.", timestamp: now + 1,
      metadata: trace_metadata
    )

    tool_calls = if with_tool_calls
                   [RSpec::Agents::Serialization::ToolCallData.new(
                     name: :weather_lookup, arguments: { city: "SF" }, timestamp: now,
                     result: { temp: 72 }
                   )]
                 else
                   []
                 end

    turn = RSpec::Agents::Serialization::TurnData.new(
      number: 1, user_message: user_msg, agent_response: agent_msg,
      tool_calls: tool_calls, topic: :weather
    )
    conversation = RSpec::Agents::Serialization::ConversationData.new(
      started_at: now, ended_at: now + 5, turns: [turn]
    )

    evaluations = if with_evaluations
                    [RSpec::Agents::Serialization::EvaluationData.new(
                      name: "accurate_response", description: "Response is accurate",
                      passed: status == :passed, reasoning: status == :passed ? "Correct weather info" : "Incorrect info", timestamp: now + 2
                    )]
                  else
                    []
                  end

    exception = if status == :failed
                  RSpec::Agents::Serialization::ExceptionData.new(
                    class_name: "RSpec::Expectations::ExpectationNotMetError",
                    message:    "Expected sunny but got rainy",
                    backtrace:  ["spec/weather_spec.rb:20", "lib/agent.rb:45"]
                  )
                end

    example = RSpec::Agents::Serialization::ExampleData.new(
      id: "weather_test_1", file: "spec/weather_spec.rb",
      description: "returns weather information",
      location: "spec/weather_spec.rb:15", started_at: now,
      status: status, finished_at: now + 5, duration_ms: 2500,
      conversation: conversation, evaluations: evaluations, exception: exception
    )

    RSpec::Agents::Serialization::RunData.new(
      run_id: "test-run-001", started_at: now, finished_at: now + 10,
      seed: 12345, examples: { "weather_test_1" => example }
    )
  end

  describe "#render" do
    it "renders HTML from RunData" do
      run_data = build_run_data
      renderer = described_class.new(run_data)
      output_path = File.join(tmp_dir,"render_test.html").to_s
      renderer.define_singleton_method(:default_output_path) { output_path }

      result = renderer.render

      expect(result).to eq(output_path)
      expect(File.exist?(output_path)).to be true

      html = File.read(output_path)
      expect(html).to include("returns weather information")
      expect(html).to include("What is the weather?")
      expect(html).to include("The weather is sunny.")
    end

    it "includes evaluation results in HTML" do
      run_data = build_run_data
      renderer = described_class.new(run_data)
      output_path = File.join(tmp_dir,"with_evaluations.html").to_s
      renderer.define_singleton_method(:default_output_path) { output_path }

      renderer.render

      html = File.read(output_path)
      expect(html).to include("accurate_response")
    end

    it "includes tool calls in HTML" do
      run_data = build_run_data(with_tool_calls: true)
      renderer = described_class.new(run_data)
      output_path = File.join(tmp_dir,"with_tool_calls.html").to_s
      renderer.define_singleton_method(:default_output_path) { output_path }

      renderer.render

      html = File.read(output_path)
      expect(html).to include("weather_lookup")
    end

    it "preserves trace metadata for templates" do
      run_data = build_run_data(with_traces: true)
      renderer = described_class.new(run_data)
      output_path = File.join(tmp_dir,"with_traces.html").to_s
      renderer.define_singleton_method(:default_output_path) { output_path }

      renderer.render

      html = File.read(output_path)
      # Default template shows metadata section with traces
      expect(html).to include("Metadata")
    end

  end

  describe "#summary_data" do
    it "returns criterion names and rows" do
      run_data = build_run_data
      renderer = described_class.new(run_data)

      summary = renderer.summary_data

      expect(summary[:criterion_names]).to eq(["accurate_response"])
      expect(summary[:rows].size).to eq(1)
      expect(summary[:rows].first[:description]).to eq("returns weather information")
    end

    it "includes criterion_map in rows" do
      run_data = build_run_data
      renderer = described_class.new(run_data)

      row = renderer.summary_data[:rows].first

      expect(row[:criterion_map]["accurate_response"][:satisfied]).to be true
      expect(row[:criterion_map]["accurate_response"][:reasoning]).to eq("Correct weather info")
    end
  end
end

RSpec.describe RSpec::Agents::Serialization::ExamplePresenter do
  let(:now) { Time.now }

  let(:user_message) do
    RSpec::Agents::Serialization::MessageData.new(
      role: :user, content: "Hello", timestamp: now,
      metadata: { topic: "greeting" }
    )
  end

  let(:agent_message) do
    RSpec::Agents::Serialization::MessageData.new(
      role: :agent, content: "Hi there!", timestamp: now + 1,
      metadata: { traces: [{ "model" => "test" }] }
    )
  end

  let(:tool_call) do
    RSpec::Agents::Serialization::ToolCallData.new(
      name: :search, arguments: { query: "test" }, timestamp: now,
      result: "found"
    )
  end

  let(:turn) do
    RSpec::Agents::Serialization::TurnData.new(
      number: 1, user_message: user_message, agent_response: agent_message,
      tool_calls: [tool_call]
    )
  end

  let(:conversation) do
    RSpec::Agents::Serialization::ConversationData.new(
      started_at: now, turns: [turn]
    )
  end

  let(:evaluation) do
    RSpec::Agents::Serialization::EvaluationData.new(
      name: "test_criterion", description: "Test description",
      passed: true, reasoning: "Good response", timestamp: now + 2
    )
  end

  let(:example_data) do
    RSpec::Agents::Serialization::ExampleData.new(
      id: "ex1", file: "spec/test.rb", description: "greets user",
      location: "spec/test.rb:10", started_at: now, status: :passed,
      duration_ms: 1500, conversation: conversation, evaluations: [evaluation]
    )
  end

  subject(:presenter) { described_class.new(example_data) }

  describe "hash-style access" do
    it "returns example_id for [:id]" do
      expect(presenter[:id]).to eq("ex1")
    end

    it "returns description for [:description]" do
      expect(presenter[:description]).to eq("greets user")
    end

    it "returns status for [:status]" do
      expect(presenter[:status]).to eq(:passed)
    end

    it "returns duration in seconds for [:duration]" do
      expect(presenter[:duration]).to eq(1.5)
    end

    it "returns messages array for [:messages]" do
      messages = presenter[:messages]
      expect(messages.size).to eq(2)
      expect(messages[0].role).to eq("user")
      expect(messages[1].role).to eq("agent")
    end

    it "returns criterion results for [:criterion_results]" do
      results = presenter[:criterion_results]
      expect(results.size).to eq(1)
      expect(results.first.name).to eq("test_criterion")
    end
  end

  describe "#messages" do
    it "flattens turns into messages" do
      messages = presenter.messages
      expect(messages.size).to eq(2)
      expect(messages[0].content).to eq("Hello")
      expect(messages[1].content).to eq("Hi there!")
    end

    it "attaches tool_calls to agent messages" do
      messages = presenter.messages
      agent_msg = messages.find { |m| m.role == "agent" }
      expect(agent_msg.tool_calls).to be_an(Array)
      expect(agent_msg.tool_calls.first[:name]).to eq("search")
    end
  end

  describe "#to_h" do
    it "serializes to hash" do
      hash = presenter.to_h
      expect(hash[:example_id]).to eq("ex1")
      expect(hash[:description]).to eq("greets user")
      expect(hash[:duration]).to eq(1.5)
    end
  end
end

RSpec.describe RSpec::Agents::Serialization::MessagePresenter do
  let(:now) { Time.now }

  let(:message_data) do
    RSpec::Agents::Serialization::MessageData.new(
      role: :agent, content: "Hello!", timestamp: now,
      metadata: { traces: [{ "model" => "test" }] }
    )
  end

  let(:tool_calls) do
    [RSpec::Agents::Serialization::ToolCallData.new(
      name: :search, arguments: { q: "test" }, timestamp: now, result: "found"
    )]
  end

  subject(:presenter) { described_class.new(message_data, tool_calls: tool_calls) }

  it "returns role" do
    expect(presenter.role).to eq("agent")
    expect(presenter[:role]).to eq("agent")
  end

  it "returns content" do
    expect(presenter.content).to eq("Hello!")
    expect(presenter[:content]).to eq("Hello!")
  end

  it "returns formatted tool_calls" do
    tc = presenter.tool_calls
    expect(tc).to be_an(Array)
    expect(tc.first[:name]).to eq("search")
    expect(tc.first[:result]).to eq("found")
  end

  it "returns metadata as hash" do
    meta = presenter.metadata
    expect(meta).to be_a(Hash)
    expect(meta[:traces]).to be_an(Array)
  end
end

RSpec.describe RSpec::Agents::Serialization::EvaluationPresenter do
  let(:now) { Time.now }

  let(:evaluation) do
    RSpec::Agents::Serialization::EvaluationData.new(
      name: "test_criterion", description: "Test desc",
      passed: true, reasoning: "Good", timestamp: now
    )
  end

  subject(:presenter) { described_class.new(evaluation) }

  it "provides name" do
    expect(presenter.name).to eq("test_criterion")
    expect(presenter[:name]).to eq("test_criterion")
  end

  it "provides description" do
    expect(presenter.description).to eq("Test desc")
  end

  it "provides satisfied?" do
    expect(presenter.satisfied?).to be true
    expect(presenter[:satisfied]).to be true
  end

  it "provides reasoning" do
    expect(presenter.reasoning).to eq("Good")
  end

  it "provides to_h" do
    hash = presenter.to_h
    expect(hash[:name]).to eq("test_criterion")
    expect(hash[:satisfied]).to be true
  end

  context "when evaluation failed" do
    let(:evaluation) do
      RSpec::Agents::Serialization::EvaluationData.new(
        name: "test", description: "desc",
        passed: false, reasoning: "Bad", timestamp: now
      )
    end

    it "returns false for satisfied?" do
      expect(presenter.satisfied?).to be false
      expect(presenter[:satisfied]).to be false
    end
  end
end

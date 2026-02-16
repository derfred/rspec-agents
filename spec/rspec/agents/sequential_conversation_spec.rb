# frozen_string_literal: true

require "spec_helper"
require "rspec/agents"
require "tempfile"

# Integration test: verifies that SequentialSpecExecutor correctly captures
# conversation turns in run_data. This guards against a regression where
# the executor's IsolatedEventBus was not injected into the thread-local,
# causing Conversation to publish events to the singleton EventBus while
# RunDataBuilder listened on a different (isolated) bus - resulting in
# empty conversation turns in JSON output.
RSpec.describe "Sequential executor conversation capture", type: :integration do
  let(:temp_dir) { Dir.mktmpdir("rspec_agents_seq_test") }

  after do
    FileUtils.rm_rf(temp_dir) if temp_dir && File.exist?(temp_dir)
  end

  def write_fixture_spec(filename, content)
    path = File.join(temp_dir, filename)
    File.write(path, content)
    path
  end

  # Shared preamble for fixture specs that use the agent DSL.
  # Defines a simple mock agent inline so specs are self-contained.
  def agent_dsl_preamble
    <<~RUBY
      require "rspec/agents"

      # Minimal mock agent that echoes back canned responses.
      # Guard with defined? to avoid constant redefinition warnings when
      # multiple SequentialSpecExecutor runs share the same Ruby process.
      unless defined?(FixtureMockAgent)
        class FixtureMockAgent < RSpec::Agents::Agents::Base
          RESPONSES = []

          def self.enqueue(*texts)
            RESPONSES.clear
            texts.each { |t| RESPONSES << t }
          end

          def chat(messages, on_tool_call: nil)
            text = RESPONSES.shift || "mock response"
            tool_calls = []

            # Support responses that include tool calls via [text, [tool_calls]] tuples
            if text.is_a?(Array)
              text, tool_calls = text
              tool_calls = (tool_calls || []).map do |tc|
                t = RSpec::Agents::ToolCall.new(**tc)
                on_tool_call&.call(t)
                t
              end
            end

            RSpec::Agents::AgentResponse.new(text: text, tool_calls: tool_calls)
          end
        end
      end

      RSpec::Agents.configure { |c| c.agent = FixtureMockAgent }
    RUBY
  end

  describe "SequentialSpecExecutor" do
    it "captures conversation turns in run_data" do
      spec_path = write_fixture_spec("conversation_spec.rb", <<~RUBY)
        #{agent_dsl_preamble}

        RSpec.describe "Fixture: conversation capture", type: :agent do
          it "records a multi-turn conversation with tool calls" do
            FixtureMockAgent.enqueue(
              "Hi! How can I help you?",
              ["I'll book that for you.", [{ name: :book_room, arguments: { room_type: "single" }, result: { status: "booked" } }]]
            )

            user.says "Hello, I need help"
            expect(agent).to satisfy(->(turn) { turn.agent_response.text.include?("help") })

            user.says "Book a room please"
            expect(agent).to satisfy(->(turn) {
              turn.tool_calls.any? { |tc| tc.name == :book_room }
            })
          end
        end
      RUBY

      executor = RSpec::Agents::SequentialSpecExecutor.new
      result = executor.execute([spec_path])

      expect(result.success?).to be(true), "Fixture spec should pass, got: #{result.inspect}"

      run_data = executor.run_data
      expect(run_data).not_to be_nil
      expect(run_data.examples.size).to eq(1)

      example = run_data.examples.values.first
      expect(example.status).to eq(:passed)
      expect(example.conversation).not_to be_nil

      turns = example.conversation.turns
      expect(turns).not_to be_empty, "Conversation turns should not be empty (event bus mismatch bug)"
      expect(turns.size).to eq(2)

      # Verify first turn content
      expect(turns[0].user_message.content).to eq("Hello, I need help")
      expect(turns[0].agent_response.content).to eq("Hi! How can I help you?")

      # Verify second turn content with tool calls
      expect(turns[1].user_message.content).to eq("Book a room please")
      expect(turns[1].agent_response.content).to eq("I'll book that for you.")
      expect(turns[1].tool_calls.size).to eq(1)
      expect(turns[1].tool_calls[0].name.to_s).to eq("book_room")

      # Verify evaluations were captured
      expect(example.evaluations.size).to eq(2)
    end

    it "captures conversations from multiple examples" do
      spec_path = write_fixture_spec("multi_example_spec.rb", <<~RUBY)
        #{agent_dsl_preamble}

        RSpec.describe "Fixture: multiple conversations", type: :agent do
          it "first conversation" do
            FixtureMockAgent.enqueue("Response to first")

            user.says "First test"
            expect(agent).to satisfy(->(turn) { turn.agent_response.text.include?("first") })
          end

          it "second conversation" do
            FixtureMockAgent.enqueue("Response to second", "Follow up response")

            user.says "Second test"
            user.says "Follow up"
            expect(agent).to satisfy(->(turn) { !turn.agent_response.text.empty? })
          end
        end
      RUBY

      executor = RSpec::Agents::SequentialSpecExecutor.new
      result = executor.execute([spec_path])

      expect(result.success?).to be(true)

      run_data = executor.run_data
      expect(run_data.examples.size).to eq(2)

      # First example: 1 turn
      first = run_data.examples.values.find { |e| e.description.include?("first") }
      expect(first.conversation.turns.size).to eq(1)
      expect(first.conversation.turns[0].user_message.content).to eq("First test")

      # Second example: 2 turns
      second = run_data.examples.values.find { |e| e.description.include?("second") }
      expect(second.conversation.turns.size).to eq(2)
      expect(second.conversation.turns[0].user_message.content).to eq("Second test")
      expect(second.conversation.turns[1].user_message.content).to eq("Follow up")
    end

    it "captures evaluations recorded via the DSL" do
      spec_path = write_fixture_spec("evaluation_spec.rb", <<~RUBY)
        #{agent_dsl_preamble}

        RSpec.describe "Fixture: evaluations", type: :agent do
          criterion :concise, "Agent response is concise"

          it "records soft and hard evaluations" do
            FixtureMockAgent.enqueue("Sure, I can help!")

            user.says "Help me"

            # Hard assertion (lambda)
            expect(agent).to satisfy(->(turn) { turn.agent_response.text.length < 500 })

            # Soft assertion (lambda)
            evaluate(agent).to satisfy(->(turn) { turn.agent_response.text.include?("help") })
          end
        end
      RUBY

      executor = RSpec::Agents::SequentialSpecExecutor.new
      result = executor.execute([spec_path])

      expect(result.success?).to be(true)

      example = executor.run_data.examples.values.first
      expect(example.conversation.turns.size).to eq(1)
      expect(example.evaluations.size).to eq(2)
    end

    it "does not leak event bus between executor runs" do
      spec_path = write_fixture_spec("leak_check_spec.rb", <<~RUBY)
        require "rspec/agents"

        RSpec.describe "Fixture: leak check" do
          it "passes" do
            expect(true).to be(true)
          end
        end
      RUBY

      executor = RSpec::Agents::SequentialSpecExecutor.new
      executor.execute([spec_path])

      expect(Thread.current[:rspec_agents_event_bus]).to be_nil,
        "Thread-local event bus should be cleaned up after execution"
    end
  end
end

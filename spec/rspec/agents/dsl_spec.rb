require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::DSL do
  describe RSpec::Agents::DSL::CriterionDefinition do
    describe "#initialize" do
      it "accepts name and simple description" do
        criterion = described_class.new(:friendly, description: "Be friendly")
        expect(criterion.name).to eq(:friendly)
        expect(criterion.description).to eq("Be friendly")
      end

      it "accepts block for complex definition" do
        criterion = described_class.new(:grounded) do
          description "Must be grounded"
          good_example "Price is 500 EUR", explanation: "Specific price"
          bad_example "Around 400-600", explanation: "Vague"
        end

        expect(criterion.description).to eq("Must be grounded")
        expect(criterion.good_examples.length).to eq(1)
        expect(criterion.bad_examples.length).to eq(1)
      end
    end

    describe "#good_example" do
      it "stores good examples" do
        criterion = described_class.new(:test) do
          good_example "Example 1", explanation: "Why it's good"
          good_example "Example 2", explanation: "Also good"
        end

        expect(criterion.good_examples.length).to eq(2)
        expect(criterion.good_examples.first[:text]).to eq("Example 1")
      end
    end

    describe "#bad_example" do
      it "stores bad examples" do
        criterion = described_class.new(:test) do
          bad_example "Bad text", explanation: "Why it's bad"
        end

        expect(criterion.bad_examples.length).to eq(1)
      end
    end

    describe "#edge_case" do
      it "stores edge cases with verdict" do
        criterion = described_class.new(:test) do
          edge_case "Edge text", verdict: true, explanation: "Acceptable"
          edge_case "Another edge", verdict: false, explanation: "Not acceptable"
        end

        expect(criterion.edge_cases.length).to eq(2)
        expect(criterion.edge_cases.first[:verdict]).to be true
      end
    end

    describe "#match" do
      it "stores match block for code-based evaluation" do
        criterion = described_class.new(:tool_called) do
          match { |conversation| conversation.called_tool?(:search) }
        end

        expect(criterion.match_block).to be_a(Proc)
        expect(criterion.code_based?).to be true
      end
    end

    describe "#has_examples?" do
      it "returns true when examples present" do
        criterion = described_class.new(:test) do
          good_example "Example", explanation: "Why"
        end
        expect(criterion.has_examples?).to be true
      end

      it "returns false when no examples" do
        criterion = described_class.new(:test, description: "Simple")
        expect(criterion.has_examples?).to be false
      end
    end
  end

  describe "TopicDSL integration" do
    let(:test_class) do
      Class.new do
        extend RSpec::Agents::DSL::TopicDSL::ClassMethods
        include RSpec::Agents::DSL::TopicDSL

        topic :greeting do
          characteristic "Initial contact"
          agent_intent "Welcome user"
        end

        criterion :friendly, "The agent should be friendly"
      end
    end

    describe ".topic" do
      it "defines shared topics" do
        expect(test_class.shared_topics[:greeting]).to be_a(RSpec::Agents::Topic)
        expect(test_class.shared_topics[:greeting].characteristic_text).to eq("Initial contact")
      end
    end

    describe ".criterion" do
      it "defines simple criteria" do
        expect(test_class.criteria[:friendly]).to be_a(RSpec::Agents::DSL::CriterionDefinition)
        expect(test_class.criteria[:friendly].description).to eq("The agent should be friendly")
      end
    end
  end

  describe "SimulatorDSL" do
    let(:parent_class) do
      Class.new do
        extend RSpec::Agents::DSL::SimulatorDSL::ClassMethods
        include RSpec::Agents::DSL::SimulatorDSL

        simulator do
          role "Corporate event planner"
          personality do
            note "Professional"
          end
          max_turns 15
          rule :should, "be polite"
        end
      end
    end

    describe ".simulator" do
      it "stores config at class level" do
        expect(parent_class.simulator_configs.length).to eq(1)
      end
    end

    describe "#simulator_config" do
      it "builds effective config" do
        instance = parent_class.new
        config = instance.simulator_config

        expect(config.effective_role).to eq(["Corporate event planner"])
        expect(config.max_turns).to eq(15)
      end
    end

    describe "user.simulate" do
      let(:simulate_test_class) do
        Class.new do
          extend RSpec::Agents::DSL::SimulatorDSL::ClassMethods
          include RSpec::Agents::DSL::SimulatorDSL
          include RSpec::Agents::DSL::ScriptedDSL
          include RSpec::Agents::DSL::ConfigurationDSL
          include RSpec::Agents::DSL::TopicDSL

          simulator do
            role "Customer"
          end
        end
      end

      let(:mock_agent) do
        Class.new(RSpec::Agents::Agents::Base) do
          def chat(messages, on_tool_call: nil)
            RSpec::Agents::AgentResponse.new(text: "Hello!")
          end
        end.new
      end

      before do
        RSpec::Agents.configuration.agent = mock_agent
      end

      it "requires a goal" do
        instance = simulate_test_class.new

        expect {
          instance.user.simulate {}
        }.to raise_error(ArgumentError, /requires a goal/)
      end

      it "requires a topic graph before running" do
        instance = simulate_test_class.new

        expect {
          instance.user.simulate do
            goal "Find a venue for 50 attendees"
          end
        }.to raise_error(RuntimeError, /No topic graph defined/)
      end
    end
  end

  describe "ExpectationDSL" do
    describe RSpec::Agents::DSL::GraphBuilder do
      it "adds inline topic to graph" do
        builder = described_class.new

        builder.topic :greeting, next: :gathering do
          characteristic "Initial contact"
        end

        builder.topic :gathering do
          characteristic "Collecting info"
        end

        graph = builder.build
        graph.validate!

        expect(graph[:greeting]).to be_a(RSpec::Agents::Topic)
        expect(graph.successors_of(:greeting)).to eq([:gathering])
      end

      it "wires shared topic into graph" do
        shared_topics = {
          greeting: RSpec::Agents::Topic.new(:greeting) { characteristic "Shared greeting" }
        }

        builder = described_class.new(shared_topics)

        builder.use_topic :greeting, next: :gathering
        builder.topic :gathering do
          characteristic "Collecting info"
        end

        graph = builder.build
        graph.validate!

        expect(graph[:greeting].characteristic_text).to eq("Shared greeting")
      end
    end

    describe "integration" do
      let(:test_class) do
        Class.new do
          extend RSpec::Agents::DSL::TopicDSL::ClassMethods
          include RSpec::Agents::DSL::TopicDSL
          include RSpec::Agents::DSL::ExpectationDSL

          topic :greeting do
            characteristic "Initial contact"
          end
        end
      end

      it "builds and validates topic graph" do
        instance = test_class.new

        graph = instance.expect_conversation_to do
          use_topic :greeting, next: :details
          topic :details do
            characteristic "Gathering details"
          end
        end

        expect(graph).to be_a(RSpec::Agents::TopicGraph)
        expect(graph.initial_topic).to eq(:greeting)
      end
    end
  end

  describe "ScriptedDSL" do
    # ConversationState tests moved to conversation_spec.rb
    # The Conversation class now handles conversation state tracking

    describe "integration" do
      let(:test_class) do
        Class.new do
          # Include all required DSL modules (ScriptedDSL needs ConfigurationDSL for build_agent)
          include RSpec::Agents::DSL::ScriptedDSL
          include RSpec::Agents::DSL::ConfigurationDSL
          include RSpec::Agents::DSL::TopicDSL

          def expect(*args); MockExpectation.new; end

          def trigger_agent_response
            response = RSpec::Agents::AgentResponse.new(text: "How can I help you?")
            conversation.add_agent_response(response)
          end
        end
      end

      # Mock agent that returns a simple response
      let(:mock_agent) do
        Class.new(RSpec::Agents::Agents::Base) do
          def chat(messages, on_tool_call: nil)
            RSpec::Agents::AgentResponse.new(text: "How can I help you?")
          end
        end.new
      end

      before do
        RSpec::Agents.configuration.agent = mock_agent
      end

      class MockExpectation
        def to(*args); true; end
      end

      it "populates conversation on user.says" do
        instance = test_class.new

        instance.user.says "Hello"

        expect(instance.conversation.messages.length).to eq(2)
        expect(instance.conversation.turns.length).to eq(1)
      end

      it "provides user and agent proxies" do
        instance = test_class.new

        user_proxy = instance.user
        user_proxy.says "Test"

        expect(user_proxy).to be_a(RSpec::Agents::DSL::UserProxy)
      end
    end
  end
end

require "spec_helper"
require "rspec/agents"

RSpec.describe "Agent context with let variables" do
  # Mock agent that stores the context it receives
  class ContextCapturingAgent < RSpec::Agents::Agents::Base
    attr_reader :captured_context

    def self.build(context = {})
      new(context: context)
    end

    def initialize(context: {})
      super(context: context)
      @captured_context = context
    end

    def chat(messages, on_tool_call: nil)
      RSpec::Agents::AgentResponse.new(text: "Mock response")
    end
  end

  describe "agent block with let variables" do
    let(:test_class) do
      Class.new do
        include RSpec::Agents::DSL

        # Define let variables in the test class
        attr_accessor :shop, :person

        def initialize
          @shop = { id: 123, name: "Test Shop" }
          @person = { id: 456, name: "Test Person" }
        end

        # Configure agent with access to let variables
        agent do |context|
          ContextCapturingAgent.build(context.merge(shop: shop, person: person))
        end
      end
    end

    it "can access let variables in agent block" do
      instance = test_class.new
      agent = instance.build_agent

      expect(agent).to be_a(ContextCapturingAgent)
      expect(agent.captured_context[:shop]).to eq(id: 123, name: "Test Shop")
      expect(agent.captured_context[:person]).to eq(id: 456, name: "Test Person")
    end

    it "receives context hash from framework" do
      instance = test_class.new

      # Simulate RSpec environment
      allow(RSpec).to receive(:current_example).and_return(
        double(
          full_description: "test example",
          file_path:        "spec/test_spec.rb",
          location:         "spec/test_spec.rb:10",
          metadata:         {}
        )
      )

      agent = instance.build_agent

      expect(agent.captured_context[:test_name]).to eq("test example")
      expect(agent.captured_context[:test_file]).to eq("spec/test_spec.rb")
    end
  end

  describe "backward compatibility" do
    let(:test_class) do
      Class.new do
        include RSpec::Agents::DSL

        attr_accessor :shop

        def initialize
          @shop = { id: 999, name: "Shop" }
        end

        agent do |context|
          # Old style with explicit merge still works
          ContextCapturingAgent.build(context.merge(shop: shop))
        end
      end
    end

    it "supports existing merge pattern" do
      instance = test_class.new
      agent = instance.build_agent

      expect(agent.captured_context[:shop]).to eq(id: 999, name: "Shop")
    end
  end

  describe "agent defined as class" do
    let(:test_class) do
      Class.new do
        include RSpec::Agents::DSL

        agent ContextCapturingAgent
      end
    end

    it "works with class-based agent configuration" do
      instance = test_class.new
      agent = instance.build_agent

      expect(agent).to be_a(ContextCapturingAgent)
    end
  end

  describe "without RSpec context" do
    let(:test_class) do
      Class.new do
        include RSpec::Agents::DSL

        attr_accessor :value

        def initialize
          @value = "test"
        end

        agent do |context|
          ContextCapturingAgent.build(context.merge(custom: value))
        end
      end
    end

    it "falls back gracefully when no RSpec example is available" do
      # Ensure no RSpec context
      allow(RSpec).to receive(:respond_to?).with(:current_example).and_return(false)

      instance = test_class.new
      agent = instance.build_agent

      expect(agent).to be_a(ContextCapturingAgent)
      expect(agent.captured_context[:custom]).to eq("test")
    end
  end

  describe "with nested describe blocks" do
    let(:parent_class) do
      Class.new do
        include RSpec::Agents::DSL

        attr_accessor :parent_var

        def initialize
          @parent_var = "parent"
        end

        agent do |context|
          ContextCapturingAgent.build(context.merge(parent: parent_var))
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        attr_accessor :child_var

        def initialize
          super
          @child_var = "child"
        end

        # Override agent configuration
        agent do |context|
          ContextCapturingAgent.build(context.merge(parent: parent_var, child: child_var))
        end
      end
    end

    it "allows child to override parent agent configuration" do
      child_instance = child_class.new
      agent = child_instance.build_agent

      expect(agent.captured_context[:parent]).to eq("parent")
      expect(agent.captured_context[:child]).to eq("child")
    end
  end

  describe "real RSpec integration", type: :agent do
    # Use real RSpec let! and let
    let!(:eager_var) { "eager_value" }
    let(:lazy_var) { "lazy_value" }

    agent do |context|
      ContextCapturingAgent.build(context.merge(
        eager: eager_var,
        lazy:  lazy_var
      ))
    end

    it "works with real RSpec let variables" do
      agent = build_agent

      expect(agent).to be_a(ContextCapturingAgent)
      expect(agent.captured_context[:eager]).to eq("eager_value")
      expect(agent.captured_context[:lazy]).to eq("lazy_value")
    end

    it "has access to test metadata" do
      agent = build_agent

      expect(agent.captured_context[:test_name]).to include("has access to test metadata")
      expect(agent.captured_context[:test_file]).to include("agent_context_spec.rb")
    end
  end

  describe "super() syntax", type: :agent do
    # Set up global configuration with an adapter class
    before do
      RSpec::Agents.configuration.agent = ContextCapturingAgent
    end

    # Use real RSpec let variables
    let(:shop) { { id: 123, name: "Test Shop" } }
    let(:person) { { id: 456, name: "Test Person" } }

    # Use super() syntax to pass additional context
    agent { super(shop: shop, person: person) }

    it "delegates to global adapter class with merged context" do
      agent = build_agent

      expect(agent).to be_a(ContextCapturingAgent)
      expect(agent.captured_context[:shop]).to eq(id: 123, name: "Test Shop")
      expect(agent.captured_context[:person]).to eq(id: 456, name: "Test Person")
    end

    it "includes framework context in merged hash" do
      agent = build_agent

      expect(agent.captured_context[:test_name]).to include("includes framework context")
      expect(agent.captured_context[:test_file]).to include("agent_context_spec.rb")
    end
  end

  describe "super() syntax without RSpec context" do
    let(:test_class) do
      Class.new do
        include RSpec::Agents::DSL

        attr_accessor :shop, :person

        def initialize
          @shop = { id: 789, name: "Non-RSpec Shop" }
          @person = { id: 101, name: "Non-RSpec Person" }
        end

        agent { super(shop: shop, person: person) }
      end
    end

    before do
      RSpec::Agents.configuration.agent = ContextCapturingAgent
    end

    it "works outside RSpec context" do
      instance = test_class.new
      agent = instance.build_agent

      expect(agent).to be_a(ContextCapturingAgent)
      expect(agent.captured_context[:shop]).to eq(id: 789, name: "Non-RSpec Shop")
      expect(agent.captured_context[:person]).to eq(id: 101, name: "Non-RSpec Person")
    end
  end
end

require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Criterion do
  describe ".from" do
    context "with a Symbol" do
      it "creates a named criterion" do
        criterion = described_class.from(:friendly)

        expect(criterion.name).to eq("friendly")
        expect(criterion.named?).to be true
        expect(criterion.type).to eq(:named)
      end

      it "stores the symbol as evaluatable" do
        criterion = described_class.from(:friendly)

        expect(criterion.evaluatable).to eq(:friendly)
      end
    end

    context "with a String" do
      it "creates an adhoc criterion" do
        criterion = described_class.from("Response is concise")

        expect(criterion.name).to eq("Response is concise")
        expect(criterion.adhoc?).to be true
        expect(criterion.type).to eq(:adhoc)
      end

      it "stores the string as evaluatable" do
        criterion = described_class.from("Response is concise")

        expect(criterion.evaluatable).to eq("Response is concise")
      end
    end

    context "with a Proc" do
      it "creates a lambda criterion" do
        proc = ->(turn) { turn.text.length < 100 }
        criterion = described_class.from(proc)

        expect(criterion.name).to eq("lambda")
        expect(criterion.lambda?).to be true
        expect(criterion.type).to eq(:lambda)
      end

      it "stores the proc as evaluatable" do
        proc = ->(turn) { turn.text.length < 100 }
        criterion = described_class.from(proc)

        expect(criterion.evaluatable).to eq(proc)
      end
    end

    context "with Symbol and Proc (named lambda)" do
      it "creates a named lambda criterion" do
        proc = ->(turn) { turn.text.length < 100 }
        criterion = described_class.from(:concise, proc)

        expect(criterion.name).to eq("concise")
        expect(criterion.lambda?).to be true
        expect(criterion.type).to eq(:lambda)
      end

      it "stores the proc as evaluatable" do
        proc = ->(turn) { turn.text.length < 100 }
        criterion = described_class.from(:concise, proc)

        expect(criterion.evaluatable).to eq(proc)
      end
    end

    context "with a CriterionDefinition" do
      it "creates a definition criterion" do
        definition = RSpec::Agents::DSL::CriterionDefinition.new(:test_def, description: "A test")
        criterion = described_class.from(definition)

        expect(criterion.name).to eq("test_def")
        expect(criterion.definition?).to be true
        expect(criterion.type).to eq(:definition)
      end

      it "stores the definition as evaluatable" do
        definition = RSpec::Agents::DSL::CriterionDefinition.new(:test_def, description: "A test")
        criterion = described_class.from(definition)

        expect(criterion.evaluatable).to eq(definition)
      end
    end

    context "with a Criterion (passthrough)" do
      it "returns the same criterion" do
        original = described_class.from(:friendly)
        result = described_class.from(original)

        expect(result).to be(original)
      end
    end

    context "with invalid arguments" do
      it "raises ArgumentError for unsupported types" do
        expect { described_class.from(123) }.to raise_error(ArgumentError, /Cannot create Criterion/)
      end

      it "raises ArgumentError for wrong two-argument combination" do
        expect { described_class.from("string", "another") }.to raise_error(ArgumentError, /Expected \(Symbol, Proc\)/)
      end

      it "raises ArgumentError for too many arguments" do
        expect { described_class.from(:a, :b, :c) }.to raise_error(ArgumentError, /Expected 1 or 2 arguments/)
      end
    end
  end

  describe ".parse" do
    it "parses a single symbol" do
      criteria = described_class.parse(:friendly)

      expect(criteria.size).to eq(1)
      expect(criteria[0].name).to eq("friendly")
      expect(criteria[0].named?).to be true
    end

    it "parses multiple symbols" do
      criteria = described_class.parse(:friendly, :helpful)

      expect(criteria.size).to eq(2)
      expect(criteria[0].name).to eq("friendly")
      expect(criteria[1].name).to eq("helpful")
    end

    it "parses a single string" do
      criteria = described_class.parse("Response is concise")

      expect(criteria.size).to eq(1)
      expect(criteria[0].name).to eq("Response is concise")
      expect(criteria[0].adhoc?).to be true
    end

    it "parses a single lambda" do
      proc = ->(turn) { true }
      criteria = described_class.parse(proc)

      expect(criteria.size).to eq(1)
      expect(criteria[0].name).to eq("lambda")
      expect(criteria[0].lambda?).to be true
    end

    it "parses a named lambda (symbol followed by proc)" do
      proc = ->(turn) { true }
      criteria = described_class.parse(:concise, proc)

      expect(criteria.size).to eq(1)
      expect(criteria[0].name).to eq("concise")
      expect(criteria[0].lambda?).to be true
    end

    it "parses mixed criteria" do
      proc = ->(turn) { true }
      criteria = described_class.parse(:friendly, "Short response", proc)

      expect(criteria.size).to eq(3)
      expect(criteria[0].name).to eq("friendly")
      expect(criteria[0].named?).to be true
      expect(criteria[1].name).to eq("Short response")
      expect(criteria[1].adhoc?).to be true
      expect(criteria[2].name).to eq("lambda")
      expect(criteria[2].lambda?).to be true
    end

    it "parses complex mixed criteria with named lambda" do
      proc1 = ->(turn) { true }
      proc2 = ->(turn) { false }
      criteria = described_class.parse(
        :friendly,
        "Short response",
        :concise, proc1,
        proc2
      )

      expect(criteria.size).to eq(4)
      expect(criteria[0].name).to eq("friendly")
      expect(criteria[1].name).to eq("Short response")
      expect(criteria[2].name).to eq("concise")
      expect(criteria[2].lambda?).to be true
      expect(criteria[3].name).to eq("lambda")
    end

    it "handles arrays (flattens them)" do
      criteria = described_class.parse([:friendly, :helpful])

      expect(criteria.size).to eq(2)
      expect(criteria[0].name).to eq("friendly")
      expect(criteria[1].name).to eq("helpful")
    end

    it "passes through existing Criterion objects" do
      existing = described_class.from(:existing)
      criteria = described_class.parse(:friendly, existing, :helpful)

      expect(criteria.size).to eq(3)
      expect(criteria[1]).to be(existing)
    end
  end

  describe "#evaluate" do
    let(:turn) { double("Turn", agent_response: double(text: "Hello world")) }

    context "lambda criterion" do
      it "evaluates the lambda and returns satisfied: true when lambda returns truthy" do
        criterion = described_class.from(->(t) { t.agent_response.text.include?("Hello") })
        result = criterion.evaluate(turn: turn)

        expect(result[:satisfied]).to be true
        expect(result[:reasoning]).to eq("Lambda passed")
      end

      it "evaluates the lambda and returns satisfied: false when lambda returns falsy" do
        criterion = described_class.from(->(t) { t.agent_response.text.include?("Goodbye") })
        result = criterion.evaluate(turn: turn)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to eq("Lambda failed")
      end

      it "handles lambda errors gracefully" do
        criterion = described_class.from(->(t) { raise "oops" })
        result = criterion.evaluate(turn: turn)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("Lambda error")
        expect(result[:reasoning]).to include("oops")
      end
    end

    context "named criterion (Symbol)" do
      let(:judge) { double("Judge") }
      let(:conversation) { double("Conversation") }
      let(:definition) { RSpec::Agents::DSL::CriterionDefinition.new(:friendly, description: "Agent is friendly") }
      let(:criteria_registry) { { friendly: definition } }

      it "returns error when no judge configured" do
        criterion = described_class.from(:friendly)
        result = criterion.evaluate(turn: turn, judge: nil, criteria_registry: criteria_registry)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("No judge configured")
      end

      it "returns error when criterion not found in registry" do
        criterion = described_class.from(:unknown)
        result = criterion.evaluate(turn: turn, judge: judge, conversation: conversation, criteria_registry: {})

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("Unknown criterion")
      end

      it "delegates to judge for LLM-based evaluation" do
        allow(judge).to receive(:evaluate_criterion)
          .with(definition, [turn], conversation)
          .and_return({ satisfied: true, reasoning: "Agent was friendly" })

        criterion = described_class.from(:friendly)
        result = criterion.evaluate(
          turn:              turn,
          judge:             judge,
          conversation:      conversation,
          criteria_registry: criteria_registry
        )

        expect(result[:satisfied]).to be true
        expect(result[:reasoning]).to eq("Agent was friendly")
      end
    end

    context "adhoc criterion (String)" do
      let(:judge) { double("Judge") }
      let(:conversation) { double("Conversation") }

      it "returns error when no judge configured" do
        criterion = described_class.from("Response is short")
        result = criterion.evaluate(turn: turn, judge: nil)

        expect(result[:satisfied]).to be false
        expect(result[:reasoning]).to include("No judge configured")
      end

      it "creates adhoc definition and delegates to judge" do
        allow(judge).to receive(:evaluate_criterion) do |definition, turns, conv|
          expect(definition).to be_a(RSpec::Agents::DSL::CriterionDefinition)
          expect(definition.name).to eq(:adhoc)
          expect(definition.description).to eq("Response is short")
          { satisfied: true, reasoning: "Response was short" }
        end

        criterion = described_class.from("Response is short")
        result = criterion.evaluate(turn: turn, judge: judge, conversation: conversation)

        expect(result[:satisfied]).to be true
      end
    end

    context "definition criterion" do
      let(:judge) { double("Judge") }
      let(:conversation) { double("Conversation", messages: []) }

      context "with code-based evaluation (match block)" do
        it "evaluates match block with conversation" do
          definition = RSpec::Agents::DSL::CriterionDefinition.new(:has_greeting) do
            match { |conv| conv.messages.any? { |m| m.include?("hello") } }
          end

          allow(conversation).to receive(:messages).and_return(["hello world"])

          criterion = described_class.from(definition)
          result = criterion.evaluate(turn: turn, conversation: conversation)

          expect(result[:satisfied]).to be true
          expect(result[:reasoning]).to eq("Code-based criterion passed")
        end

        it "returns failed when match block returns false" do
          definition = RSpec::Agents::DSL::CriterionDefinition.new(:has_greeting) do
            match { |conv| false }
          end

          criterion = described_class.from(definition)
          result = criterion.evaluate(turn: turn, conversation: conversation)

          expect(result[:satisfied]).to be false
          expect(result[:reasoning]).to eq("Code-based criterion failed")
        end
      end

      context "with code-based evaluation (match_messages block)" do
        it "evaluates match_messages block with messages array" do
          definition = RSpec::Agents::DSL::CriterionDefinition.new(:has_greeting) do
            match_messages { |msgs| msgs.any? { |m| m.include?("hello") } }
          end

          allow(conversation).to receive(:messages).and_return(["hello world"])

          criterion = described_class.from(definition)
          result = criterion.evaluate(turn: turn, conversation: conversation)

          expect(result[:satisfied]).to be true
        end
      end

      context "with LLM-based evaluation (no code block)" do
        it "delegates to judge" do
          definition = RSpec::Agents::DSL::CriterionDefinition.new(:friendly, description: "Agent is friendly")

          allow(judge).to receive(:evaluate_criterion)
            .with(definition, [turn], conversation)
            .and_return({ satisfied: true, reasoning: "Was friendly" })

          criterion = described_class.from(definition)
          result = criterion.evaluate(turn: turn, judge: judge, conversation: conversation)

          expect(result[:satisfied]).to be true
        end

        it "returns error when no judge and no code block" do
          definition = RSpec::Agents::DSL::CriterionDefinition.new(:friendly, description: "Agent is friendly")

          criterion = described_class.from(definition)
          result = criterion.evaluate(turn: turn, conversation: conversation)

          expect(result[:satisfied]).to be false
          expect(result[:reasoning]).to include("No judge configured")
        end
      end
    end
  end

  describe "#display_name" do
    it "returns the name" do
      criterion = described_class.from(:friendly)
      expect(criterion.display_name).to eq("friendly")
    end
  end

  describe "#to_s" do
    it "returns a string representation" do
      criterion = described_class.from(:friendly)
      expect(criterion.to_s).to eq("Criterion(friendly)")
    end
  end

  describe "#inspect" do
    it "returns a detailed inspection string" do
      criterion = described_class.from(:friendly)
      expect(criterion.inspect).to eq('#<Criterion name="friendly" type=named>')
    end
  end

  describe "type predicates" do
    it "#named? returns true only for symbol criteria" do
      expect(described_class.from(:friendly).named?).to be true
      expect(described_class.from("string").named?).to be false
      expect(described_class.from(->(_) {}).named?).to be false
    end

    it "#adhoc? returns true only for string criteria" do
      expect(described_class.from("string").adhoc?).to be true
      expect(described_class.from(:friendly).adhoc?).to be false
      expect(described_class.from(->(_) {}).adhoc?).to be false
    end

    it "#lambda? returns true only for proc criteria" do
      expect(described_class.from(->(_) {}).lambda?).to be true
      expect(described_class.from(:friendly).lambda?).to be false
      expect(described_class.from("string").lambda?).to be false
    end

    it "#definition? returns true only for CriterionDefinition criteria" do
      defn = RSpec::Agents::DSL::CriterionDefinition.new(:test, description: "test")
      expect(described_class.from(defn).definition?).to be true
      expect(described_class.from(:friendly).definition?).to be false
    end
  end
end

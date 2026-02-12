require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::SimulatorConfig do
  describe "#initialize" do
    it "starts with empty arrays and nil values" do
      config = described_class.new
      expect(config.effective_role).to eq([])
      expect(config.effective_personality).to eq([])
      expect(config.effective_context).to eq([])
      expect(config.rules).to eq([])
      expect(config.max_turns).to be_nil
    end
  end

  describe "#role" do
    it "sets role as string and returns as array" do
      config = described_class.new
      config.role "Corporate event planner"
      expect(config.effective_role).to eq(["Corporate event planner"])
    end
  end

  describe "#personality" do
    it "sets personality as string and returns as array" do
      config = described_class.new
      config.personality "Professional and efficient"
      expect(config.effective_personality).to eq(["Professional and efficient"])
    end

    it "sets personality as block with notes and returns as array" do
      config = described_class.new
      config.personality do
        note "Professional demeanor"
        note "Values efficiency"
      end
      expect(config.effective_personality).to eq(["Professional demeanor", "Values efficiency"])
    end
  end

  describe "#context" do
    it "sets context as string and returns as array" do
      config = described_class.new
      config.context "Works at Acme Corp"
      expect(config.effective_context).to eq(["Works at Acme Corp"])
    end

    it "sets context as block with notes and returns as array" do
      config = described_class.new
      config.context do
        note "Based in Stuttgart"
        note "Budget: 30,000-50,000 EUR"
      end
      expect(config.effective_context).to eq(["Based in Stuttgart", "Budget: 30,000-50,000 EUR"])
    end
  end

  describe "#rule" do
    it "adds :should rules" do
      config = described_class.new
      config.rule :should, "confirm understanding before searches"
      expect(config.rules).to eq([{ type: :should, text: "confirm understanding before searches" }])
    end

    it "adds :should_not rules" do
      config = described_class.new
      config.rule :should_not, "engage in small talk"
      expect(config.rules).to eq([{ type: :should_not, text: "engage in small talk" }])
    end

    it "adds dynamic rules with lambda" do
      rule_lambda = ->(msg, conv) { "Express urgency" if conv.turns.count > 5 }
      config = described_class.new
      config.rule rule_lambda
      expect(config.rules.first[:type]).to eq(:dynamic)
      expect(config.rules.first[:block]).to eq(rule_lambda)
    end

    it "adds dynamic rules with block" do
      config = described_class.new
      config.rule do |msg, conv|
        "Express urgency" if conv.turns.count > 5
      end
      expect(config.rules.first[:type]).to eq(:dynamic)
      expect(config.rules.first[:block]).to be_a(Proc)
    end
  end

  describe "#max_turns" do
    it "sets and gets max_turns" do
      config = described_class.new
      config.max_turns 15
      expect(config.max_turns).to eq(15)
    end
  end

  describe "#stop_when" do
    it "sets stop condition block" do
      config = described_class.new
      config.stop_when do |turn, conversation|
        conversation.has_tool_call?(:book_venue)
      end
      expect(config.stop_when).to be_a(Proc)
    end
  end

  describe "#goal" do
    it "sets and gets goal" do
      config = described_class.new
      config.goal "Find a venue for 50 attendees"
      expect(config.goal).to eq("Find a venue for 50 attendees")
    end
  end

  describe "#during_topic" do
    it "stores topic-specific overrides" do
      config = described_class.new
      config.personality "Normal"
      config.during_topic :gathering_details do
        personality "Extra cautious"
        rule :should, "double-check every detail"
      end

      expect(config.topic_overrides[:gathering_details]).to be_a(described_class)
      expect(config.topic_overrides[:gathering_details].effective_personality).to eq(["Extra cautious"])
    end
  end

  describe "#merge" do
    describe "role inheritance" do
      it "child string replaces parent string" do
        parent = described_class.new
        parent.role "Parent role"

        child = described_class.new
        child.role "Child role"

        merged = parent.merge(child)
        expect(merged.effective_role).to eq(["Child role"])
      end

      it "inherits parent when child has no role" do
        parent = described_class.new
        parent.role "Parent role"

        child = described_class.new

        merged = parent.merge(child)
        expect(merged.effective_role).to eq(["Parent role"])
      end
    end

    describe "personality inheritance" do
      it "child string replaces parent string" do
        parent = described_class.new
        parent.personality "Parent personality"

        child = described_class.new
        child.personality "Child personality"

        merged = parent.merge(child)
        expect(merged.effective_personality).to eq(["Child personality"])
      end

      it "child string replaces parent block" do
        parent = described_class.new
        parent.personality do
          note "Professional"
          note "Friendly"
        end

        child = described_class.new
        child.personality "Impatient, tight deadline"

        merged = parent.merge(child)
        expect(merged.effective_personality).to eq(["Impatient, tight deadline"])
      end

      it "child block replaces parent string" do
        parent = described_class.new
        parent.personality "Simple personality"

        child = described_class.new
        child.personality do
          note "Detailed note 1"
          note "Detailed note 2"
        end

        merged = parent.merge(child)
        expect(merged.effective_personality).to eq(["Detailed note 1", "Detailed note 2"])
      end

      it "block + block merges notes" do
        parent = described_class.new
        parent.personality do
          note "Professional"
        end

        child = described_class.new
        child.personality do
          note "Also friendly"
        end

        merged = parent.merge(child)
        expect(merged.effective_personality).to eq(["Professional", "Also friendly"])
      end

      it "inherits parent when child has no personality" do
        parent = described_class.new
        parent.personality "Parent personality"

        child = described_class.new

        merged = parent.merge(child)
        expect(merged.effective_personality).to eq(["Parent personality"])
      end
    end

    describe "rules inheritance" do
      it "always accumulates rules" do
        parent = described_class.new
        parent.rule :should, "be polite"

        child = described_class.new
        child.rule :should_not, "be rude"

        merged = parent.merge(child)
        expect(merged.rules.length).to eq(2)
        expect(merged.rules[0]).to eq({ type: :should, text: "be polite" })
        expect(merged.rules[1]).to eq({ type: :should_not, text: "be rude" })
      end
    end

    describe "max_turns inheritance" do
      it "child replaces parent" do
        parent = described_class.new
        parent.max_turns 15

        child = described_class.new
        child.max_turns 8

        merged = parent.merge(child)
        expect(merged.max_turns).to eq(8)
      end

      it "inherits parent when child has no max_turns" do
        parent = described_class.new
        parent.max_turns 15

        child = described_class.new

        merged = parent.merge(child)
        expect(merged.max_turns).to eq(15)
      end
    end

    describe "stop_when inheritance" do
      it "child replaces parent" do
        parent_block = ->(t, c) { c.turns.count > 10 }
        child_block = ->(t, c) { c.has_tool_call?(:done) }

        parent = described_class.new
        parent.stop_when(&parent_block)

        child = described_class.new
        child.stop_when(&child_block)

        merged = parent.merge(child)
        expect(merged.stop_when).to eq(child_block)
      end
    end

    describe "goal inheritance" do
      it "child takes precedence" do
        parent = described_class.new
        parent.goal "Parent goal"

        child = described_class.new
        child.goal "Child goal"

        merged = parent.merge(child)
        expect(merged.goal).to eq("Child goal")
      end
    end

    describe "topic_overrides inheritance" do
      it "merges topic overrides from both" do
        parent = described_class.new
        parent.during_topic :topic_a do
          personality "Override A"
        end

        child = described_class.new
        child.during_topic :topic_b do
          personality "Override B"
        end

        merged = parent.merge(child)
        expect(merged.topic_overrides.keys).to contain_exactly(:topic_a, :topic_b)
      end

      it "child override replaces parent for same topic" do
        parent = described_class.new
        parent.during_topic :same do
          personality "Parent override"
        end

        child = described_class.new
        child.during_topic :same do
          personality "Child override"
        end

        merged = parent.merge(child)
        expect(merged.topic_overrides[:same].effective_personality).to eq(["Child override"])
      end
    end
  end

  describe "#for_topic" do
    it "returns config with topic overrides applied" do
      config = described_class.new
      config.personality "Normal"
      config.during_topic :urgent do
        personality "Rushed"
        rule :should, "express time pressure"
      end

      topic_config = config.for_topic(:urgent)
      expect(topic_config.effective_personality).to eq(["Rushed"])
      expect(topic_config.rules.length).to eq(1)
    end

    it "returns self when no override for topic" do
      config = described_class.new
      config.personality "Normal"

      topic_config = config.for_topic(:unknown)
      expect(topic_config).to eq(config)
    end
  end

  describe "full DSL example from design doc" do
    it "supports the complete simulator block syntax" do
      config = described_class.new
      config.instance_eval do
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
          # Would check for tool call in real usage
          false
        end
      end

      expect(config.effective_role).to eq(["Corporate event planner at Acme GmbH"])
      expect(config.effective_personality).to include("Professional demeanor")
      expect(config.effective_context).to include("Works at Acme GmbH, based in Stuttgart")
      expect(config.rules.length).to eq(2)
      expect(config.max_turns).to eq(15)
      expect(config.stop_when).to be_a(Proc)
    end
  end
end

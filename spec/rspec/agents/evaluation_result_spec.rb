require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::EvaluationResult do
  describe "#initialize" do
    it "creates an evaluation result with all parameters" do
      result = described_class.new(
        mode:            :soft,
        type:            :quality,
        description:     "test criterion",
        passed:          true,
        failure_message: nil,
        metadata:        { turn_number: 1 }
      )

      expect(result.mode).to eq(:soft)
      expect(result.type).to eq(:quality)
      expect(result.description).to eq("test criterion")
      expect(result.passed).to be true
      expect(result.failure_message).to be_nil
      expect(result.metadata).to eq({ turn_number: 1 })
    end

    it "creates a failed soft evaluation" do
      result = described_class.new(
        mode:            :soft,
        type:            :quality,
        description:     "failing criterion",
        passed:          false,
        failure_message: "Expected something else"
      )

      expect(result.passed).to be false
      expect(result.failure_message).to eq("Expected something else")
    end

    it "creates a hard evaluation" do
      result = described_class.new(
        mode:        :hard,
        type:        :tool_call,
        description: "call_tool(:search)",
        passed:      true
      )

      expect(result.mode).to eq(:hard)
      expect(result.hard?).to be true
      expect(result.soft?).to be false
    end
  end

  describe "#soft?" do
    it "returns true for soft mode" do
      result = described_class.new(mode: :soft, type: :quality, description: "test", passed: true)
      expect(result.soft?).to be true
    end

    it "returns false for hard mode" do
      result = described_class.new(mode: :hard, type: :quality, description: "test", passed: true)
      expect(result.soft?).to be false
    end
  end

  describe "#hard?" do
    it "returns true for hard mode" do
      result = described_class.new(mode: :hard, type: :quality, description: "test", passed: true)
      expect(result.hard?).to be true
    end

    it "returns false for soft mode" do
      result = described_class.new(mode: :soft, type: :quality, description: "test", passed: true)
      expect(result.hard?).to be false
    end
  end

  describe "#to_h" do
    it "returns hash representation" do
      result = described_class.new(
        mode:            :soft,
        type:            :quality,
        description:     "test",
        passed:          false,
        failure_message: "Failed",
        metadata:        { turn: 1 }
      )

      hash = result.to_h
      expect(hash).to eq({
        mode:            :soft,
        type:            :quality,
        description:     "test",
        passed:          false,
        failure_message: "Failed",
        metadata:        { turn: 1 }
      })
    end
  end
end

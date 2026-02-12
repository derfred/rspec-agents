require "spec_helper"
require "rspec/agents"

RSpec.describe "Expectation Wrappers" do
  let(:conversation) { RSpec::Agents::Conversation.new }
  let(:target_value) { "test value" }

  # Simple matcher for testing wrapper behavior
  class PassingMatcher
    def matches?(_actual)
      true
    end

    def description
      "always pass"
    end

    def failure_message
      "should not see this"
    end

    def failure_message_when_negated
      "expected not to pass, but it did"
    end
  end

  class FailingMatcher
    def matches?(_actual)
      false
    end

    def description
      "always fail"
    end

    def failure_message
      "expected to pass, but it failed"
    end

    def failure_message_when_negated
      "should not see this"
    end
  end

  describe RSpec::Agents::DSL::BaseExpectationWrapper do
    it "is abstract and raises NotImplementedError for mode" do
      wrapper = described_class.new(target_value, conversation: conversation)
      expect { wrapper.send(:mode) }.to raise_error(NotImplementedError, /must implement #mode/)
    end

    it "is abstract and raises NotImplementedError for on_pass" do
      wrapper = described_class.new(target_value, conversation: conversation)
      expect { wrapper.send(:on_pass, double, false) }.to raise_error(NotImplementedError)
    end

    it "is abstract and raises NotImplementedError for on_fail" do
      wrapper = described_class.new(target_value, conversation: conversation)
      expect { wrapper.send(:on_fail, double, false, "message") }.to raise_error(NotImplementedError)
    end
  end

  describe RSpec::Agents::DSL::HardExpectationWrapper do
    let(:wrapper) { described_class.new(target_value, conversation: conversation) }

    it "has mode :hard" do
      expect(wrapper.send(:mode)).to eq(:hard)
    end

    describe "positive expectations" do
      it "returns true when matcher passes" do
        result = wrapper.to(PassingMatcher.new)
        expect(result).to eq(true)
      end

      it "raises ExpectationNotMetError when matcher fails" do
        expect { wrapper.to(FailingMatcher.new) }.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected to pass, but it failed"
        )
      end

      it "records evaluation to conversation when passing" do
        wrapper.to(PassingMatcher.new)
        expect(conversation.evaluation_results.size).to eq(1)
        result = conversation.evaluation_results.first
        expect(result.mode).to eq(:hard)
        expect(result.passed).to eq(true)
      end

      it "records evaluation to conversation when failing" do
        expect { wrapper.to(FailingMatcher.new) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
        expect(conversation.evaluation_results.size).to eq(1)
        result = conversation.evaluation_results.first
        expect(result.mode).to eq(:hard)
        expect(result.passed).to eq(false)
        expect(result.failure_message).to eq("expected to pass, but it failed")
      end
    end

    describe "negative expectations" do
      it "returns true when matcher fails (negated pass)" do
        result = wrapper.not_to(FailingMatcher.new)
        expect(result).to eq(true)
      end

      it "raises ExpectationNotMetError when matcher passes (negated fail)" do
        expect { wrapper.not_to(PassingMatcher.new) }.to raise_error(
          RSpec::Expectations::ExpectationNotMetError,
          "expected not to pass, but it did"
        )
      end

      it "records evaluation with negated description" do
        wrapper.not_to(FailingMatcher.new)
        expect(conversation.evaluation_results.size).to eq(1)
        result = conversation.evaluation_results.first
        expect(result.description).to start_with("not_to ")
      end
    end
  end

  describe RSpec::Agents::DSL::SoftExpectationWrapper do
    let(:wrapper) { described_class.new(target_value, conversation: conversation) }

    it "has mode :soft" do
      expect(wrapper.send(:mode)).to eq(:soft)
    end

    describe "positive expectations" do
      it "returns nil when matcher passes" do
        result = wrapper.to(PassingMatcher.new)
        expect(result).to be_nil
      end

      it "returns nil when matcher fails (suppresses error)" do
        result = wrapper.to(FailingMatcher.new)
        expect(result).to be_nil
      end

      it "records passing evaluation to conversation" do
        wrapper.to(PassingMatcher.new)
        expect(conversation.evaluation_results.size).to eq(1)
        result = conversation.evaluation_results.first
        expect(result.mode).to eq(:soft)
        expect(result.passed).to eq(true)
      end

      it "records failing evaluation to conversation without raising" do
        wrapper.to(FailingMatcher.new)
        expect(conversation.evaluation_results.size).to eq(1)
        result = conversation.evaluation_results.first
        expect(result.mode).to eq(:soft)
        expect(result.passed).to eq(false)
        expect(result.failure_message).to eq("expected to pass, but it failed")
      end
    end

    describe "negative expectations" do
      it "returns nil for negated expectations that pass" do
        result = wrapper.not_to(FailingMatcher.new)
        expect(result).to be_nil
      end

      it "returns nil for negated expectations that fail (suppresses error)" do
        result = wrapper.not_to(PassingMatcher.new)
        expect(result).to be_nil
      end
    end
  end

  describe "matcher type extraction" do
    let(:hard_wrapper) { RSpec::Agents::DSL::HardExpectationWrapper.new(target_value, conversation: conversation) }

    it "identifies SatisfyMatcher as :quality" do
      matcher = RSpec::Agents::Matchers::SatisfyMatcher.new([:friendly])
      # SatisfyMatcher needs a runner, so it will fail, but we can still check the recorded type
      expect { hard_wrapper.to(matcher) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      expect(conversation.evaluation_results.first.type).to eq(:quality)
    end

    it "identifies CallToolMatcher as :tool_call" do
      matcher = RSpec::Agents::Matchers::CallToolMatcher.new(:some_tool)
      expect { hard_wrapper.to(matcher) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      expect(conversation.evaluation_results.first.type).to eq(:tool_call)
    end

    it "identifies unknown matchers as :custom" do
      matcher = FailingMatcher.new
      expect { hard_wrapper.to(matcher) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      expect(conversation.evaluation_results.first.type).to eq(:custom)
    end
  end
end

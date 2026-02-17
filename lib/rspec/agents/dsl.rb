require_relative "dsl/criterion_definition"
require_relative "dsl/graph_builder"
require_relative "dsl/test_context"
require_relative "dsl/runner_factory"
require_relative "dsl/user_proxy"
require_relative "dsl/agent_proxy"
require_relative "dsl/scenario_set_dsl"

module RSpec
  module Agents
    # DSL module for RSpec integration
    # Provides the full API for writing agent tests
    module DSL
      # Shared module that provides access to the test context
      # Included by all DSL sub-modules that need context access
      module TestContextAccess
        private

        def rspec_agents_test_context
          @rspec_agents_test_context ||= TestContext.new(
            test_class:             self.class,
            rspec_example:          defined?(RSpec) && RSpec.respond_to?(:current_example) ? RSpec.current_example : nil,
            rspec_example_instance: self,
            scenario:               instance_variable_defined?(:@rspec_agents_current_scenario) ? @rspec_agents_current_scenario : nil
          )
        end
      end

      def self.included(base)
        base.include(TopicDSL)
        base.include(SimulatorDSL)
        base.include(ExpectationDSL)
        base.include(ScriptedDSL)
        base.include(ConfigurationDSL)
        base.include(ScenarioSetDSL)
      end

      # ========================================
      # TopicDSL - Define topics and criteria
      # ========================================
      module TopicDSL
        def self.included(base)
          base.extend(ClassMethods)
          base.include(TestContextAccess)
        end

        module ClassMethods
          def topic(name, &block)
            shared_topics[name.to_sym] = Topic.new(name, &block)
          end

          def criterion(name, description = nil, &block)
            criteria[name.to_sym] = if block_given?
                                      CriterionDefinition.new(name, &block)
                                    else
                                      CriterionDefinition.new(name, description: description)
                                    end
          end

          def shared_topics
            @shared_topics ||= {}
          end

          def criteria
            @criteria ||= {}
          end
        end

        def accumulated_topics
          rspec_agents_test_context.topics
        end

        def accumulated_criteria
          rspec_agents_test_context.criteria
        end
      end

      # ========================================
      # ConfigurationDSL - Per-test configuration
      # ========================================
      module ConfigurationDSL
        def self.included(base)
          base.extend(ClassMethods)
          base.include(TestContextAccess)
        end

        module ClassMethods
          # Set agent for this describe block
          #
          # Supports multiple syntaxes:
          #
          # 1. Class-based (uses Class.build(context)):
          #    agent MyAgentClass
          #
          # 2. Block with context argument (full control):
          #    agent { |context| MyAgent.build(context.merge(shop: shop)) }
          #
          # 3. Block with super (delegates to global adapter):
          #    agent { super(shop: shop, person: person) }
          #
          # The super syntax allows specifying only the context additions
          # while delegating to the globally configured agent adapter class.
          # The adapter class's .build method receives the merged context.
          #
          # @param agent_or_proc [Class, Proc, Agents::Base] Agent configuration
          def agent(agent_or_proc = nil, &block)
            @agent_override = block_given? ? block : agent_or_proc
          end

          # Set judge configuration for this describe block
          def judge(&block)
            @judge_override = block
          end

          def agent_override
            @agent_override
          end

          def judge_override
            @judge_override
          end
        end

        # Build agent instance from configuration
        def build_agent
          rspec_agents_test_context.build_agent
        end

        # Build judge instance
        def build_judge(llm)
          rspec_agents_test_context.build_judge(llm)
        end

        # Build LLM instance
        def build_llm
          rspec_agents_test_context.build_llm
        end
      end

      # ========================================
      # SimulatorDSL - Configure and run simulator
      # ========================================
      module SimulatorDSL
        def self.included(base)
          base.extend(ClassMethods)
          base.include(TestContextAccess)
        end

        module ClassMethods
          def simulator(&block)
            config = SimulatorConfig.new
            config.instance_eval(&block) if block_given?
            simulator_configs << config
          end

          def simulator_configs
            @simulator_configs ||= []
          end
        end

        def simulator_config
          rspec_agents_test_context.simulator_config
        end
      end

      # ========================================
      # ExpectationDSL - Define conversation graph
      # ========================================
      module ExpectationDSL
        def self.included(base)
          base.include(TestContextAccess)
        end

        def expect_conversation_to(&block)
          builder = GraphBuilder.new(rspec_agents_test_context.topics)
          builder.instance_eval(&block)
          graph = builder.build
          graph.validate!
          rspec_agents_test_context.topic_graph = graph
          graph
        end

        def topic_graph
          rspec_agents_test_context.topic_graph
        end
      end

      # ========================================
      # ScriptedDSL - Run scripted conversations
      # ========================================
      module ScriptedDSL
        def self.included(base)
          base.include(TestContextAccess)
        end

        def user
          ensure_turn_executor_initialized
          @user_proxy
        end

        def agent
          ensure_turn_executor_initialized
          @agent_proxy
        end

        def conversation
          rspec_agents_test_context.conversation
        end

        # Override RSpec's expect() to inject conversation context and record evaluations
        # Handles both expect(value) and expect { block } forms
        def expect(target = ::RSpec::Expectations::ExpectationTarget::UndefinedValue, &block)
          # If block given or target undefined, delegate to RSpec's standard expect
          # This handles block expectations like: expect { }.to raise_error
          if block || target == ::RSpec::Expectations::ExpectationTarget::UndefinedValue
            return super(target, &block)
          end

          # For value expectations like expect(agent), use our wrapper
          ensure_turn_executor_initialized
          HardExpectationWrapper.new(target, conversation: conversation)
        end

        # Soft evaluation - records result without failing test
        def evaluate(target)
          ensure_turn_executor_initialized
          SoftExpectationWrapper.new(target, conversation: conversation)
        end

        private

        def ensure_turn_executor_initialized
          return if @turn_executor

          context = rspec_agents_test_context
          factory = RunnerFactory.new(context)
          @turn_executor = context.turn_executor
          @user_proxy = UserProxy.new(
            context:        context,
            turn_executor:  @turn_executor,
            runner_factory: factory
          )
          @agent_proxy = factory.build_agent_proxy
        end
      end

      # ========================================
      # BaseExpectationWrapper - Shared logic for hard and soft expectations
      # ========================================
      # The wrapper is responsible for:
      # 1. Running the matcher
      # 2. Recording the evaluation result to the conversation
      # 3. Handling pass/fail behavior based on mode (hard vs soft)
      #
      # Matchers remain unchanged standard RSpec matchers - they should NOT
      # know about evaluation modes or recording. The wrapper extracts all
      # necessary information from the matcher after running it.
      class BaseExpectationWrapper
        def initialize(target, conversation:)
          @target = target
          @conversation = conversation
        end

        def to(matcher)
          handle_expectation(matcher, negated: false)
        end

        def not_to(matcher)
          handle_expectation(matcher, negated: true)
        end

        protected

        # Subclasses must implement these
        def mode
          raise NotImplementedError, "#{self.class} must implement #mode"
        end

        def on_pass(matcher, negated)
          raise NotImplementedError, "#{self.class} must implement #on_pass"
        end

        def on_fail(matcher, negated, failure_message)
          raise NotImplementedError, "#{self.class} must implement #on_fail"
        end

        private

        def handle_expectation(matcher, negated:)
          passed = run_matcher(matcher, negated)
          failure_message = passed ? nil : extract_failure_message(matcher, negated)

          record_evaluation(matcher, passed, failure_message, negated)

          if passed
            on_pass(matcher, negated)
          else
            on_fail(matcher, negated, failure_message)
          end
        end

        def run_matcher(matcher, negated)
          result = matcher.matches?(@target)
          negated ? !result : result
        end

        def extract_failure_message(matcher, negated)
          if negated
            matcher.failure_message_when_negated if matcher.respond_to?(:failure_message_when_negated)
          else
            matcher.failure_message if matcher.respond_to?(:failure_message)
          end
        end

        def record_evaluation(matcher, passed, failure_message, negated)
          return unless @conversation

          @conversation.record_evaluation(
            mode:            mode,
            type:            extract_matcher_type(matcher),
            description:     extract_description(matcher, negated),
            passed:          passed,
            failure_message: failure_message,
            metadata:        extract_metadata(matcher)
          )
        end

        def extract_matcher_type(matcher)
          # Map matcher class to evaluation type
          case matcher
          when Matchers::SatisfyMatcher then :quality
          when Matchers::CallToolMatcher then :tool_call
          when Matchers::BeGroundedInMatcher then :grounding
          when Matchers::ClaimMatcher then :forbidden_claims
          when Matchers::HaveIntentMatcher then :intent
          when Matchers::BeInTopicMatcher then :topic
          when Matchers::HaveReachedTopicMatcher then :topic_history
          when Matchers::HaveToolCallMatcher then :conversation_tool_call
          when Matchers::HaveAchievedStatedGoalMatcher, Matchers::HaveAchievedGoalMatcher then :goal_achievement
          else :custom
          end
        end

        def extract_description(matcher, negated)
          prefix = negated ? "not_to " : ""
          if matcher.respond_to?(:description)
            "#{prefix}#{matcher.description}"
          else
            "#{prefix}#{matcher.class.name.split('::').last}"
          end
        end

        def extract_metadata(matcher)
          return {} unless matcher.respond_to?(:evaluation_metadata)
          matcher.evaluation_metadata
        end
      end

      # ========================================
      # HardExpectationWrapper - Records evaluations and fails on mismatch
      # ========================================
      class HardExpectationWrapper < BaseExpectationWrapper
        protected

        def mode
          :hard
        end

        def on_pass(_matcher, _negated)
          true
        end

        def on_fail(matcher, negated, failure_message)
          # Raise RSpec expectation failure
          raise RSpec::Expectations::ExpectationNotMetError, failure_message
        end
      end

      # ========================================
      # SoftExpectationWrapper - Records evaluations without failing test
      # ========================================
      class SoftExpectationWrapper < BaseExpectationWrapper
        protected

        def mode
          :soft
        end

        def on_pass(_matcher, _negated)
          nil  # Always return nil for soft assertions
        end

        def on_fail(_matcher, _negated, _failure_message)
          nil  # Suppress failure, just return nil
        end
      end
    end
  end
end

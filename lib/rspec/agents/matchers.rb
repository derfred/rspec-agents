module RSpec
  module Agents
    # RSpec matchers for agent testing
    # Provides per-turn assertions for scripted conversations
    module Matchers
      # Matcher for quality criteria satisfaction
      # @example
      #   expect(agent).to satisfy(:friendly)
      #   expect(agent).to satisfy(:friendly, :helpful)
      #   expect(agent).to satisfy(->(turn) { turn.agent_response.text.length < 500 })
      #   expect(agent).to satisfy(:concise, ->(turn) { turn.agent_response.text.length <= 300 })
      def satisfy(*criteria)
        SatisfyMatcher.new(criteria)
      end

      # Matcher for tool call expectations
      # @example
      #   expect(agent).to call_tool(:search_suppliers)
      #   expect(agent).to call_tool(:book_room).with(room: "Blue Room")
      def call_tool(tool_name)
        CallToolMatcher.new(tool_name)
      end

      # Matcher for grounding verification
      # @example
      #   expect(agent).to be_grounded_in(:venues, :pricing)
      #   expect(agent).to be_grounded_in(:venues, from_tools: [:search_suppliers])
      def be_grounded_in(*claim_types, from_tools: [])
        BeGroundedInMatcher.new(claim_types, from_tools)
      end

      # Matcher for forbidden claims
      # @example
      #   expect(agent).not_to claim(:availability)
      def claim(*claim_types)
        ClaimMatcher.new(claim_types)
      end

      # Matcher for intent verification
      # @example
      #   expect(agent).to have_intent(:gather_requirements)
      #   expect(agent).to have_intent(:gather_requirements, described_as: "Ask about dates and capacity")
      def have_intent(intent_name, described_as: nil)
        HaveIntentMatcher.new(intent_name, described_as)
      end

      # Matcher for topic verification
      # @example
      #   expect(agent).to be_in_topic(:greeting)
      def be_in_topic(topic_name)
        BeInTopicMatcher.new(topic_name)
      end

      # Matcher for checking if a topic was reached at any point in conversation
      # @example
      #   expect(agent).to have_reached_topic(:confirmation)
      def have_reached_topic(topic_name)
        HaveReachedTopicMatcher.new(topic_name)
      end

      # Matcher for conversation-level tool call verification
      # @example
      #   expect(agent).to have_tool_call(:book_venue)
      #   expect(agent).to have_tool_call(:book_venue, city: "Stuttgart")
      def have_tool_call(tool_name, **params)
        HaveToolCallMatcher.new(tool_name, **params)
      end

      # Matcher for LLM-judged goal achievement against stated goal
      # @example
      #   expect(agent).to have_achieved_stated_goal
      def have_achieved_stated_goal
        HaveAchievedStatedGoalMatcher.new
      end

      # Matcher for LLM-judged goal achievement against custom description
      # @example
      #   expect(agent).to have_achieved_goal("User received venue options under budget")
      def have_achieved_goal(description)
        HaveAchievedGoalMatcher.new(description)
      end

      # ========================================
      # Matcher Implementations
      # ========================================

      # Base class for all matchers providing shared functionality
      # Matchers are standard RSpec matchers - they do NOT know about
      # evaluation modes or recording. The expectation wrapper handles that.
      class BaseMatcher
        # RSpec matcher description - used by wrappers for recording
        def description
          self.class.name.split("::").last.gsub(/Matcher$/, "").gsub(/([a-z])([A-Z])/, '\1 \2').downcase
        end

        # Optional metadata for evaluation recording
        # Subclasses can override to provide additional context
        def evaluation_metadata
          {}
        end

        protected

        def extract_runner(proxy)
          proxy.runner if proxy.respond_to?(:runner)
        end

        # Resolve conversation from target (Conversation or object with .conversation)
        def resolve_conversation(target)
          target.conversation if target.respond_to?(:conversation)
        end
      end

      class SatisfyMatcher < BaseMatcher
        def initialize(criteria)
          @criteria = Criterion.parse(*criteria.flatten)
          @results  = []
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy
          runner = extract_runner(agent_proxy)
          return false unless runner

          @results = @criteria.map do |criterion|
            result = agent_proxy.evaluate_criterion(criterion)
            { criterion: criterion.display_name, satisfied: result[:satisfied], reasoning: result[:reasoning] }
          end

          @results.all? { |r| r[:satisfied] }
        end

        def description
          criteria_list = @criteria.map(&:display_name).join(", ")
          "satisfy(#{criteria_list})"
        end

        def evaluation_metadata
          { criteria: @criteria.map(&:display_name) }
        end

        def failure_message
          failed = @results.reject { |r| r[:satisfied] }
          messages = failed.map { |r| "#{r[:criterion]}: #{r[:reasoning]}" }
          "Expected agent to satisfy criteria, but:\n  #{messages.join("\n  ")}"
        end

        def failure_message_when_negated
          "Expected agent not to satisfy criteria, but all criteria passed"
        end
      end

      class CallToolMatcher < BaseMatcher
        def initialize(tool_name)
          @tool_name       = tool_name.to_sym
          @expected_params = nil
          @actual_calls    = []
        end

        # Chain method for parameter matching
        def with(params)
          @expected_params = params
          self
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy
          runner       = extract_runner(agent_proxy)

          if runner
            @actual_calls = runner.tool_calls(@tool_name)
          elsif agent_proxy.respond_to?(:tool_calls)
            @actual_calls = agent_proxy.tool_calls.select { |tc| tc.name == @tool_name }
          elsif agent_proxy.respond_to?(:response)
            @actual_calls = agent_proxy.response&.find_tool_calls(@tool_name) || []
          else
            @actual_calls = []
          end

          if @actual_calls.empty?
            false
          elsif @expected_params
            @actual_calls.any? { |tc| params_match?(tc, @expected_params) }
          else
            true
          end
        end

        def description
          @expected_params ? "call_tool(#{@tool_name}, #{@expected_params})" : "call_tool(#{@tool_name})"
        end

        def failure_message
          if @actual_calls.empty?
            all_calls = get_all_tool_calls
            if all_calls.empty?
              "Expected agent to call tool :#{@tool_name}, but no tools were called"
            else
              names = all_calls.map { |tc| tc.respond_to?(:name) ? tc.name : tc[:name] }.uniq.join(", ")
              "Expected agent to call tool :#{@tool_name}, but called: #{names}"
            end
          else
            # Params didn't match
            actual_params = @actual_calls.map { |tc| tc.respond_to?(:arguments) ? tc.arguments : tc[:arguments] }
            "Expected tool call :#{@tool_name} with params #{@expected_params.inspect}, but got: #{actual_params.inspect}"
          end
        end

        def failure_message_when_negated
          "Expected agent not to call tool :#{@tool_name}, but it was called"
        end

        private

        def get_all_tool_calls
          if @agent_proxy.respond_to?(:tool_calls)
            @agent_proxy.tool_calls
          elsif @agent_proxy.respond_to?(:response)
            @agent_proxy.response&.tool_calls || []
          else
            []
          end
        end

        def params_match?(tool_call, expected)
          expected.all? do |key, expected_value|
            actual_value = tool_call.argument(key)

            case expected_value
            when Regexp
              expected_value.match?(actual_value.to_s)
            when Proc
              expected_value.call(actual_value)
            when RSpec::Matchers::BuiltIn::BaseMatcher
              expected_value.matches?(actual_value)
            else
              actual_value == expected_value
            end
          end
        end
      end

      class BeGroundedInMatcher < BaseMatcher
        def initialize(claim_types, from_tools)
          @claim_types = claim_types.flatten.map(&:to_sym)
          @from_tools = Array(from_tools).map(&:to_sym)
          @result = nil
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy
          runner = extract_runner(agent_proxy)

          unless runner
            @result = { grounded: false, violations: ["No runner available for grounding check"] }
            return false
          end

          @result = runner.check_grounding(@claim_types, from_tools: @from_tools)
          @result[:grounded]
        end

        def description
          "be_grounded_in(#{@claim_types.inspect})"
        end

        def failure_message
          violations = @result[:violations] || []
          "Expected agent claims to be grounded in #{@claim_types.inspect}, but:\n  #{violations.join("\n  ")}"
        end

        def failure_message_when_negated
          "Expected agent claims not to be grounded, but they were"
        end
      end

      class ClaimMatcher < BaseMatcher
        def initialize(claim_types)
          @claim_types = claim_types.flatten.map(&:to_sym)
          @result = nil
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy
          runner = extract_runner(agent_proxy)

          unless runner
            @result = { violated: false, claims_found: [] }
            return false
          end

          @result = runner.check_forbidden_claims(@claim_types)
          @result[:violated]
        end

        def description
          "claim(#{@claim_types.inspect})"
        end

        def failure_message
          "Expected agent to make claims about #{@claim_types.inspect}, but none were found"
        end

        def failure_message_when_negated
          claims = @result[:claims_found] || []
          claim_texts = claims.map { |c| c["claim"] || c[:claim] }.join(", ")
          "Expected agent not to make claims about #{@claim_types.inspect}, but found: #{claim_texts}"
        end
      end

      class HaveIntentMatcher < BaseMatcher
        def initialize(intent_name, described_as)
          @intent_name = intent_name
          @intent_description = described_as || intent_name.to_s.tr("_", " ")
          @result = nil
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy
          runner = extract_runner(agent_proxy)

          unless runner
            @result = { matches: false, reasoning: "No runner available for intent check" }
            return false
          end

          @result = runner.check_intent(@intent_description)
          @result[:matches]
        end

        def description
          "have_intent(#{@intent_name})"
        end

        def failure_message
          observed = @result[:observed_intent] || "unknown"
          reasoning = @result[:reasoning] || ""
          "Expected agent to have intent '#{@intent_description}', but observed: #{observed}\n  #{reasoning}"
        end

        def failure_message_when_negated
          "Expected agent not to have intent '#{@intent_description}', but it did"
        end
      end

      class BeInTopicMatcher < BaseMatcher
        def initialize(topic_name)
          @expected_topic = topic_name.to_sym
          @actual_topic = nil
        end

        def matches?(agent_proxy)
          @agent_proxy = agent_proxy

          if agent_proxy.respond_to?(:current_topic)
            @actual_topic = agent_proxy.current_topic
          elsif agent_proxy.respond_to?(:in_topic?)
            return agent_proxy.in_topic?(@expected_topic)
          else
            runner = extract_runner(agent_proxy)
            @actual_topic = runner&.current_topic
          end

          @actual_topic == @expected_topic
        end

        def description
          "be_in_topic(#{@expected_topic})"
        end

        def failure_message
          "Expected agent to be in topic :#{@expected_topic}, but was in :#{@actual_topic || 'none'}"
        end

        def failure_message_when_negated
          "Expected agent not to be in topic :#{@expected_topic}, but it was"
        end
      end

      class HaveReachedTopicMatcher < BaseMatcher
        def initialize(topic_name)
          @expected_topic = topic_name.to_sym
          @topic_history = []
        end

        def matches?(target)
          @target = target
          conversation = resolve_conversation(target)
          return false unless conversation

          @topic_history = conversation.topic_history.map { |entry| entry[:topic] }
          @topic_history.include?(@expected_topic)
        end

        def description
          "have_reached_topic(#{@expected_topic})"
        end

        def failure_message
          if @topic_history.empty?
            "expected conversation to have reached topic :#{@expected_topic}, but no topics were visited"
          else
            visited = @topic_history.map(&:inspect).join(", ")
            "expected conversation to have reached topic :#{@expected_topic}, but only visited: #{visited}"
          end
        end

        def failure_message_when_negated
          "expected conversation not to reach topic :#{@expected_topic}, but it was visited"
        end
      end

      class HaveToolCallMatcher < BaseMatcher
        def initialize(tool_name, **params)
          @expected_tool = tool_name.to_sym
          @expected_params = params
          @actual_calls = []
        end

        def matches?(target)
          @target = target
          conversation = resolve_conversation(target)
          return false unless conversation

          if @expected_params.empty?
            @actual_calls = conversation.find_tool_calls(@expected_tool)
          else
            @actual_calls = conversation.find_tool_calls(@expected_tool, params: @expected_params)
          end

          @actual_calls.any?
        end

        def description
          @expected_params.empty? ? "have_tool_call(#{@expected_tool})" : "have_tool_call(#{@expected_tool}, #{@expected_params})"
        end

        def failure_message
          conversation = resolve_conversation(@target)

          if @expected_params.empty?
            "expected conversation to have tool call :#{@expected_tool}, but it was never called"
          else
            all_calls = conversation&.find_tool_calls(@expected_tool) || []
            if all_calls.empty?
              "expected tool call :#{@expected_tool} with params #{@expected_params.inspect}, " \
              "but tool was never called"
            else
              actual_params = all_calls.map(&:arguments)
              "expected tool call :#{@expected_tool} with params #{@expected_params.inspect}, " \
              "but found calls with: #{actual_params.inspect}"
            end
          end
        end

        def failure_message_when_negated
          if @expected_params.empty?
            "expected conversation not to have tool call :#{@expected_tool}, " \
            "but it was called #{@actual_calls.count} time(s)"
          else
            "expected conversation not to have tool call :#{@expected_tool} " \
            "with params #{@expected_params.inspect}, but found matching call(s)"
          end
        end
      end

      class HaveAchievedStatedGoalMatcher < BaseMatcher
        def matches?(target)
          @target = target
          runner = extract_runner(target)
          return false unless runner

          conversation = resolve_conversation(target)
          judge = runner.judge

          # Get stated goal from simulator config
          @stated_goal = extract_stated_goal(runner)

          unless @stated_goal
            @error_message = "No goal was specified in user.simulate block"
            return false
          end

          @result = judge.evaluate_goal_achievement(@stated_goal, conversation)
          @achieved = @result[:achieved]
          @reasoning = @result[:reasoning]

          @achieved
        end

        def description
          "have_achieved_stated_goal"
        end

        def failure_message
          return @error_message if @error_message

          "expected conversation to achieve stated goal \"#{@stated_goal}\"\n" \
          "LLM reasoning: #{@reasoning}"
        end

        def failure_message_when_negated
          "expected conversation not to achieve stated goal \"#{@stated_goal}\", " \
          "but it was achieved\n" \
          "LLM reasoning: #{@reasoning}"
        end

        private

        def extract_stated_goal(runner)
          # Try to get goal from simulator config
          config = runner.respond_to?(:simulator_config) ? runner.simulator_config : nil
          config&.goal
        end
      end

      class HaveAchievedGoalMatcher < BaseMatcher
        def initialize(goal_description)
          @goal_description = goal_description
        end

        def matches?(target)
          @target = target
          runner = extract_runner(target)
          return false unless runner

          conversation = resolve_conversation(target)
          judge = runner.judge

          @result = judge.evaluate_goal_achievement(@goal_description, conversation)
          @achieved = @result[:achieved]
          @reasoning = @result[:reasoning]

          @achieved
        end

        def description
          "have_achieved_goal(#{@goal_description})"
        end

        def failure_message
          "expected conversation to achieve goal \"#{@goal_description}\"\n" \
          "LLM reasoning: #{@reasoning}"
        end

        def failure_message_when_negated
          "expected conversation not to achieve goal \"#{@goal_description}\", " \
          "but it was achieved\n" \
          "LLM reasoning: #{@reasoning}"
        end
      end
    end
  end
end

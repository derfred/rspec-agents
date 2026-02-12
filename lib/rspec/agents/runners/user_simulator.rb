module RSpec
  module Agents
    module Runners
      # Executes simulated conversations where an LLM generates user messages
      # based on a goal and personality, following a topic graph
      class UserSimulator
        attr_reader :conversation, :results

        # @param agent [Agents::Base] The agent under test
        # @param llm [LLM::Base] LLM for user simulation
        # @param judge [Judge] Judge for topic classification and invariant evaluation
        # @param graph [TopicGraph] The topic graph defining conversation flow
        # @param simulator_config [SimulatorConfig] Configuration for the simulator
        # @param event_bus [EventBus, nil] Optional event bus for emitting events
        # @param conversation [Conversation, nil] Optional existing conversation to use
        def initialize(agent:, llm:, judge:, graph:, simulator_config:, event_bus: nil, conversation: nil)
          @agent        = agent
          @llm          = llm
          @judge        = judge
          @graph        = graph
          @config       = simulator_config
          @event_bus    = event_bus
          @conversation = conversation || Conversation.new(event_bus: @event_bus)
          @results      = SimulationResults.new

          # Create turn executor for executing individual turns
          # Note: We pass graph: nil because SimulatedRunner handles topic transitions itself
          # (it needs to evaluate invariants on topic exit)
          @turn_executor = TurnExecutor.new(
            agent:        @agent,
            conversation: @conversation,
            graph:        nil,  # We handle topic classification ourselves
            judge:        @judge,
            event_bus:    @event_bus
          )
        end

        # Run the simulated conversation
        #
        # @return [Conversation] The completed conversation
        def run
          @current_topic = @graph.initial_topic
          @conversation.set_topic(@current_topic)
          turns_taken             = 0
          @start_time             = Time.now
          @topic_evaluation_cache = {}
          termination_reason      = nil

          # Emit simulation started event
          emit_simulation_started

          while termination_reason.nil?
            # Check termination conditions first
            termination_reason = check_termination(turns_taken)
            break if termination_reason

            # 1. Generate user message
            user_message = generate_user_message

            # 2. Execute the turn (adds message, gets response, records turn)
            @turn_executor.execute(user_message, source: :simulator)
            turn = @turn_executor.current_turn
            turn.topic = @current_topic

            # 3. Classify topic (may trigger topic change)
            new_topic = classify_topic(turn)

            # 4. Handle topic transition
            if new_topic != @current_topic
              # Evaluate invariants for the topic we're leaving
              evaluate_topic_exit(@current_topic)

              @current_topic = new_topic
              @conversation.set_topic(@current_topic)
            end

            turns_taken += 1
          end

          # Final invariant evaluation for the last topic
          evaluate_topic_exit(@current_topic)

          # Build complete results
          @results = SimulationResults.new(
            conversation:       @conversation,
            termination_reason: termination_reason,
            topic_history:      extract_topic_history,
            metadata:           build_metadata(turns_taken)
          )

          # Copy over topic evaluations
          @topic_evaluation_cache.each do |topic_name, results|
            @results.add_topic_evaluation(topic_name, results)
          end

          # Emit simulation ended event
          emit_simulation_ended(turns_taken, termination_reason)

          @conversation
        end

        # Get the simulation results (invariant evaluations, etc.)
        #
        # @return [SimulationResults]
        def simulation_results
          @results
        end

        private

        # Check if simulation should terminate
        # @return [Symbol, nil] Termination reason or nil to continue
        def check_termination(turns_taken)
          # Check max turns
          max = @config.max_turns || 15
          return :max_turns if turns_taken >= max

          # Check stop condition
          if @config.stop_when && @conversation.turns.any?
            last_turn = @conversation.turns.last
            return :stop_condition if @config.stop_when.call(last_turn, @conversation)
          end

          nil
        end

        # Extract ordered list of topic symbols from conversation history
        # @return [Array<Symbol>]
        def extract_topic_history
          @conversation.topic_history.map { |h| h[:topic] }
        end

        # Build metadata hash with timing and execution details
        # @return [Hash]
        def build_metadata(turns_taken)
          end_time = Time.now
          {
            start_time:       @start_time,
            end_time:         end_time,
            duration_seconds: end_time - @start_time,
            turn_count:       turns_taken
          }
        end

        def generate_user_message
          current_topic_obj = @graph[@current_topic]
          prompt = PromptBuilders::UserSimulation.build(
            @config,
            @conversation,
            current_topic: current_topic_obj
          )

          response = @llm.complete(prompt, response_format: :text)
          PromptBuilders::UserSimulation.parse(response)
        end

        def emit_simulation_started
          @event_bus&.publish(Events::SimulationStarted.new(
            example_id: Thread.current[:rspec_agents_example_id],
            goal:       @config.goal,
            max_turns:  @config.max_turns || 15,
            time:       Time.now
          ))
        end

        def emit_simulation_ended(turn_count, termination_reason)
          @event_bus&.publish(Events::SimulationEnded.new(
            example_id:         Thread.current[:rspec_agents_example_id],
            turn_count:         turn_count,
            termination_reason: termination_reason,
            time:               Time.now
          ))
        end

        def classify_topic(turn)
          @graph.classify(turn, @conversation, @current_topic, judge: @judge)
        end

        def evaluate_topic_exit(topic_name)
          topic = @graph[topic_name]
          return unless topic

          turns = @conversation.turns_for_topic(topic_name)
          return if turns.empty?

          # Evaluate invariants
          invariant_results = topic.evaluate_invariants(turns, @conversation, @judge)

          # Resolve pending LLM-based evaluations
          if invariant_results.has_pending?
            resolved = @judge.resolve_pending_invariants(
              invariant_results.pending,
              turns,
              @conversation
            )
            resolved.each { |r| invariant_results.add(r[:type], r[:description], r[:passed], r[:failure_message], mode: r[:mode]) }
            invariant_results.pending.clear
          end

          # Cache results for later addition to SimulationResults
          @topic_evaluation_cache[topic_name] = invariant_results
        end
      end

      # Holds results from a simulated conversation
      # Provides access to conversation, evaluations, termination reason, and metadata
      class SimulationResults
        attr_reader :conversation, :evaluations, :termination_reason, :topic_history, :metadata

        # @param conversation [Conversation] The completed conversation
        # @param termination_reason [Symbol] Why simulation ended (:goal_reached, :max_turns, :stop_condition, :error)
        # @param topic_history [Array<Symbol>] Ordered list of topics visited
        # @param metadata [Hash] Timing information, turn count, etc.
        def initialize(conversation: nil, termination_reason: nil, topic_history: [], metadata: {})
          @conversation       = conversation
          @evaluations        = []
          @termination_reason = termination_reason
          @topic_history      = topic_history
          @metadata           = metadata
        end

        def add_topic_evaluation(topic_name, results)
          @evaluations << { topic: topic_name, results: results }
        end

        def passed?
          @evaluations.all? { |e| e[:results].passed? }
        end

        def failure_messages
          @evaluations.flat_map { |e| e[:results].failures.map { |f| f[:failure_message] } }.compact
        end

        def soft_failures
          @evaluations.flat_map do |e|
            e[:results].soft_failures
          end
        end

        def hard_failures
          @evaluations.flat_map do |e|
            e[:results].hard_failures
          end
        end

        def to_h
          {
            conversation:       @conversation&.to_h,
            evaluations:        @evaluations.map { |e| { topic: e[:topic], results: e[:results].results } },
            soft_failures:      soft_failures,
            hard_failures:      hard_failures,
            termination_reason: @termination_reason,
            topic_history:      @topic_history,
            metadata:           @metadata,
            passed:             passed?
          }
        end
      end
    end
  end
end

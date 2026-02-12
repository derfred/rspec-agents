module RSpec
  module Agents
    module Llm
      # Mock LLM adapter for deterministic testing
      # Allows queuing responses and setting expected evaluation results
      class Mock < Base
        attr_reader :calls, :evaluation_results, :user_responses, :topic_classifications

        def initialize
          @calls = []
          @evaluation_results = {}
          @user_responses = []
          @topic_classifications = []
          @default_responses = {}
          @response_index = 0
          @topic_index = 0
        end

        def complete(prompt, response_format: :text, max_tokens: 1024)
          @calls << { prompt: prompt, response_format: response_format, max_tokens: max_tokens }

          text = generate_response(prompt, response_format)
          parsed = response_format == :json ? safe_parse(text) : nil

          Response.new(
            text:     text,
            parsed:   parsed,
            metadata: { model: "mock", latency_ms: 0 }
          )
        end

        def available?
          true
        end

        def model_info
          "Mock LLM"
        end

        # ---- Configuration helpers ----

        # Set expected evaluation result for a criterion
        # @param criterion [Symbol, String] Criterion name
        # @param satisfied [Boolean] Whether criterion is satisfied
        # @param reasoning [String, nil] Optional reasoning
        def set_evaluation(criterion, satisfied, reasoning = nil)
          key = criterion.to_s.downcase
          @evaluation_results[key] = {
            satisfied: satisfied,
            reasoning: reasoning || "Mock evaluation for #{criterion}"
          }
        end

        # Queue a user simulation response
        # @param response [String] The user message to return
        def queue_user_response(response)
          @user_responses << response
        end

        # Queue a topic classification result
        # @param topic [Symbol] The topic to return
        def queue_topic_classification(topic)
          @topic_classifications << topic.to_sym
        end

        # Set a default response for a prompt pattern
        # @param pattern [Regexp, String] Pattern to match in prompt
        # @param response [String] Response to return
        def set_default_response(pattern, response)
          @default_responses[pattern] = response
        end

        # Reset all state
        def reset!
          @calls.clear
          @evaluation_results.clear
          @user_responses.clear
          @topic_classifications.clear
          @default_responses.clear
          @response_index = 0
          @topic_index = 0
        end

        # Get the last prompt that was sent
        def last_prompt
          @calls.last&.dig(:prompt)
        end

        # Get all prompts that were sent
        def all_prompts
          @calls.map { |c| c[:prompt] }
        end

        private

        def generate_response(prompt, response_format)
          # Check for criterion evaluation prompts
          if prompt.include?("satisfied") || prompt.include?("criterion")
            return handle_evaluation_prompt(prompt)
          end

          # Check for user simulation prompts
          if prompt.include?("Generate") && prompt.include?("user")
            return handle_user_simulation_prompt
          end

          # Check for topic classification prompts
          if prompt.include?("topic") && prompt.include?("classify")
            return handle_topic_classification_prompt
          end

          # Check for grounding evaluation prompts
          if prompt.include?("grounded") || prompt.include?("grounding")
            return handle_grounding_prompt(prompt)
          end

          # Check default responses
          @default_responses.each do |pattern, response|
            if pattern.is_a?(Regexp) ? pattern.match?(prompt) : prompt.include?(pattern.to_s)
              return response
            end
          end

          # Generic response
          response_format == :json ? '{"result": "mock response"}' : "Mock response"
        end

        def handle_evaluation_prompt(prompt)
          # Try to match a predefined evaluation result
          @evaluation_results.each do |key, result|
            if prompt.downcase.include?(key)
              return {
                "satisfied" => result[:satisfied],
                "reasoning" => result[:reasoning]
              }.to_json
            end
          end

          # Default: satisfied
          {
            "satisfied" => true,
            "reasoning" => "Mock adapter: automatically satisfied"
          }.to_json
        end

        def handle_user_simulation_prompt
          if @response_index < @user_responses.length
            response = @user_responses[@response_index]
            @response_index += 1
            response
          else
            "Mock user response #{@response_index + 1}"
          end
        end

        def handle_topic_classification_prompt
          if @topic_index < @topic_classifications.length
            topic = @topic_classifications[@topic_index]
            @topic_index += 1
            { "topic" => topic.to_s }.to_json
          else
            { "topic" => "unknown" }.to_json
          end
        end

        def handle_grounding_prompt(prompt)
          {
            "grounded"   => true,
            "violations" => []
          }.to_json
        end

        def safe_parse(text)
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end

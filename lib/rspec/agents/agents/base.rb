module RSpec
  module Agents
    module Agents
      # Base class for agent adapters
      # Agent adapters handle communication with the chatbot being tested
      #
      # Each test execution receives a fresh agent instance, allowing per-test
      # configuration and state isolation.
      #
      # @example Implementing a custom agent
      #   class MyHttpAgent < RSpec::Agents::Agents::Base
      #     def self.build(context = {})
      #       new(
      #         base_url: ENV["AGENT_URL"],
      #         api_key: ENV["AGENT_API_KEY"],
      #         context: context
      #       )
      #     end
      #
      #     def initialize(base_url:, api_key:, context: {})
      #       super(context: context)
      #       @base_url = base_url
      #       @api_key = api_key
      #     end
      #
      #     def chat(messages, on_tool_call: nil)
      #       response = HTTParty.post("#{@base_url}/chat", ...)
      #       tool_calls = parse_tool_calls(response["tool_calls"])
      #
      #       # Signal each tool call via callback if provided
      #       tool_calls.each { |tc| on_tool_call&.call(tc) }
      #
      #       AgentResponse.new(
      #         text: response["content"],
      #         tool_calls: tool_calls,
      #         metadata: { latency_ms: elapsed }
      #       )
      #     end
      #   end
      class Base
        # Factory method called by the framework for each test
        # Override this in subclasses to customize instantiation
        #
        # @param context [Hash] Test execution context containing:
        #   - :test_name [String] Full RSpec example description
        #   - :test_file [String] Source file path
        #   - :test_line [Integer] Line number of the test
        #   - :tags [Hash] RSpec metadata tags (:focus, :slow, etc.)
        #   - :scenario [String] Scenario name if using external scenario files
        # @return [Base] Agent instance
        def self.build(context = {})
          new(context: context)
        end

        # @param context [Hash] Test execution context
        def initialize(context: {})
          @context = context
        end

        # Send messages and receive a response
        # This is the main method that subclasses must implement
        #
        # @param messages [Array<Hash, Message>] Conversation history
        #   Each message has :role ("user" or "agent") and :content
        # @param on_tool_call [Proc, nil] Optional callback invoked for each tool call
        #   Callback receives a ToolCall object as argument
        # @return [AgentResponse] The agent's response
        def chat(messages, on_tool_call: nil)
          raise NotImplementedError, "#{self.class} must implement #chat(messages, on_tool_call: nil)"
        end

        # Reset conversation state (for stateful agents)
        # Override in subclasses that maintain internal state
        def reset!
          # Default no-op
        end

        # Wrap test execution for isolation (e.g., database transactions)
        # Override in subclasses to provide custom wrapping behavior
        #
        # @yield The test block to execute
        # @return [Object] The result of the block
        #
        # @example Wrapping in a database transaction
        #   def around(&block)
        #     ActiveRecord::Base.transaction(requires_new: true) do
        #       block.call
        #       raise ActiveRecord::Rollback
        #     end
        #   end
        def around(&block)
          block.call  # Default: no-op wrapping
        end

        # Agent metadata for reporting
        # Override to provide useful debugging information
        #
        # @return [Metadata]
        def metadata
          Metadata.new
        end

        protected

        attr_reader :context

        # Helper to convert messages to a standard format
        # @param messages [Array] Messages in various formats
        # @return [Array<Hash>] Normalized messages
        def normalize_messages(messages)
          messages.map do |msg|
            case msg
            when Hash
              { role: msg[:role] || msg["role"], content: msg[:content] || msg["content"] }
            else
              { role: msg.role, content: msg.content }
            end
          end
        end
      end
    end
  end
end

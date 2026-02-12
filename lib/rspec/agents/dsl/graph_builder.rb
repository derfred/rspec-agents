module RSpec
  module Agents
    module DSL
      # Builder for constructing TopicGraph from DSL blocks
      class GraphBuilder
        # @param shared_topics [Hash<Symbol, Topic>]
        def initialize(shared_topics = {})
          @shared_topics = shared_topics
          @graph = TopicGraph.new
        end

        # Wire an existing shared topic into the graph
        # @param name [Symbol]
        # @param next [Symbol, Array<Symbol>, nil]
        def use_topic(name, next: nil, **options)
          next_topics = binding.local_variable_get(:next)
          @graph.use_topic(name.to_sym, next_topics: next_topics, shared_topics: @shared_topics)
        end

        # Define and add an inline topic to the graph
        # @param name [Symbol]
        # @param next [Symbol, Array<Symbol>, nil]
        # @yield Block for topic definition
        def topic(name, next: nil, &block)
          next_topics = binding.local_variable_get(:next)
          topic_instance = Topic.new(name, &block)
          @graph.add_topic(topic_instance, next_topics: next_topics)
        end

        # Build the final TopicGraph
        # @return [TopicGraph]
        def build
          @graph
        end
      end
    end
  end
end

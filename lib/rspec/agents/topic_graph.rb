module RSpec
  module Agents
    # Topic graph validation errors
    # Defined at module level so they can be caught before RSpec wraps them
    class TopicGraphValidationError < StandardError; end
    class DuplicateTopicError < TopicGraphValidationError; end
    class UndefinedTopicError < TopicGraphValidationError; end
    class SelfLoopError < TopicGraphValidationError; end
    class UnreachableTopicError < TopicGraphValidationError; end

    # Directed graph of topics representing conversation flow
    # Validates structure and provides traversal methods
    class TopicGraph
      attr_reader :initial_topic, :topics

      def initialize
        @topics = {}
        @edges = {}  # topic_name => [successor_names]
        @initial_topic = nil
        @topic_order = []  # Tracks order for initial topic detection
      end

      # Add a topic with its successors
      # @param topic [Topic] Topic instance
      # @param next_topics [Symbol, Array<Symbol>, nil] Successor topic name(s)
      def add_topic(topic, next_topics: nil)
        name = topic.name

        raise DuplicateTopicError, "Topic :#{name} is already defined" if @topics.key?(name)

        @topics[name] = topic
        @edges[name] = normalize_next(next_topics)
        @topic_order << name
        @initial_topic ||= name
      end

      # Reference a shared topic and wire it into the graph
      # @param name [Symbol] Topic name (must exist in shared topics or already added)
      # @param next_topics [Symbol, Array<Symbol>, nil] Successor topic name(s)
      # @param shared_topics [Hash] Hash of shared topic definitions
      def use_topic(name, next_topics: nil, shared_topics: {})
        name = name.to_sym

        if @topics.key?(name)
          # Topic already added, just update edges
          @edges[name] = normalize_next(next_topics)
        elsif shared_topics.key?(name)
          # Copy from shared topics
          shared_topic = shared_topics[name]
          @topics[name] = shared_topic
          @edges[name] = normalize_next(next_topics)
          @topic_order << name
          @initial_topic ||= name
        else
          # Create placeholder - will be validated later
          @topics[name] = nil
          @edges[name] = normalize_next(next_topics)
          @topic_order << name
          @initial_topic ||= name
        end
      end

      # Validate the graph structure
      # @raise [ValidationError] If validation fails
      def validate!
        validate_referential_integrity!
        validate_no_self_loops!
        validate_connectivity!
        wire_successors!
      end

      # Get successor topic names for a topic
      # @param topic_name [Symbol] Topic name
      # @return [Array<Symbol>]
      def successors_of(topic_name)
        @edges[topic_name.to_sym] || []
      end

      # Check if target is reachable from start
      # @param start [Symbol] Starting topic name
      # @param target [Symbol] Target topic name
      # @return [Boolean]
      def reachable_from?(start, target)
        visited = Set.new
        queue = [start.to_sym]

        while queue.any?
          current = queue.shift
          return true if current == target.to_sym

          next if visited.include?(current)
          visited << current

          queue.concat(successors_of(current))
        end

        false
      end

      # Get a topic by name
      # @param name [Symbol] Topic name
      # @return [Topic, nil]
      def [](name)
        @topics[name.to_sym]
      end

      def topic_names
        @topics.keys
      end

      def empty?
        @topics.empty?
      end

      def size
        @topics.size
      end

      # Get all terminal topics (no successors)
      def terminal_topics
        @topics.keys.select { |name| successors_of(name).empty? }
      end

      # Classify which topic a turn belongs to, given the current topic
      # Uses conservative classification: current topic triggers checked first,
      # then successor triggers, then LLM fallback if judge provided.
      #
      # @param turn [Turn] The turn to classify
      # @param conversation [Conversation] Full conversation context
      # @param current_topic [Symbol] The current topic name
      # @param judge [Judge, nil] Optional judge for LLM-based classification
      # @return [Symbol] The classified topic name
      def classify(turn, conversation, current_topic, judge: nil)
        current_topic = current_topic.to_sym
        current_topic_obj = @topics[current_topic]

        # 1. Check current topic's triggers first (conservative stay)
        if current_topic_obj&.trigger_matches?(turn, conversation)
          return current_topic
        end

        # 2. Check successor topics' triggers
        successors = successors_of(current_topic)
        successors.each do |successor_name|
          successor = @topics[successor_name]
          if successor&.trigger_matches?(turn, conversation)
            return successor_name
          end
        end

        # 3. No triggers matched - use LLM classification if judge available and successors exist
        if judge && successors.any?
          possible_topics = ([current_topic_obj] + successors.map { |s| @topics[s] }).compact
          return judge.classify_topic(turn, conversation, possible_topics)
        end

        # 4. No successors and no triggers (or no judge) - stay in current topic
        current_topic
      end

      def to_h
        {
          initial_topic: @initial_topic,
          topics:        @topics.transform_values { |t| t&.to_h },
          edges:         @edges
        }
      end

      private

      def normalize_next(next_topics)
        case next_topics
        when nil
          []
        when Symbol
          [next_topics]
        when Array
          next_topics.map(&:to_sym)
        else
          raise ArgumentError, "next: must be a Symbol, Array of Symbols, or nil"
        end
      end

      def validate_referential_integrity!
        @edges.each do |source, targets|
          targets.each do |target|
            unless @topics.key?(target)
              raise UndefinedTopicError, "Topic :#{source} references undefined topic :#{target}"
            end
          end
        end

        # Check for placeholder topics (used but never defined)
        @topics.each do |name, topic|
          if topic.nil?
            raise UndefinedTopicError, "Topic :#{name} was referenced but never defined"
          end
        end
      end

      def validate_no_self_loops!
        @edges.each do |source, targets|
          if targets.include?(source)
            raise SelfLoopError, "Topic :#{source} has a self-loop (next: [:#{source}]). Self-loops are not allowed; use conservative topic classification instead."
          end
        end
      end

      def validate_connectivity!
        return if @topics.empty?

        reachable = Set.new
        queue = [@initial_topic]

        while queue.any?
          current = queue.shift
          next if reachable.include?(current)

          reachable << current
          queue.concat(successors_of(current))
        end

        unreachable = @topics.keys - reachable.to_a
        if unreachable.any?
          raise UnreachableTopicError, "Topics #{unreachable.map { |t| ":#{t}" }.join(', ')} are not reachable from initial topic :#{@initial_topic}"
        end
      end

      def wire_successors!
        @topics.each do |name, topic|
          topic.successors = successors_of(name)
        end
      end
    end
  end
end

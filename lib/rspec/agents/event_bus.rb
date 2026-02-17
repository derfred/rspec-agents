# frozen_string_literal: true

module RSpec
  module Agents
    # Central publish/subscribe hub for events.
    # Thread-safe with error isolation (observer errors never fail tests).
    #
    # Access the current thread's event bus via EventBus.current.
    # Each thread (or worker process) gets its own independent instance.
    #
    # @example Setup in a runner/executor
    #   EventBus.current = EventBus.new
    #   # ... run specs ...
    #   EventBus.current = nil  # cleanup
    #
    # @example Consuming in observers
    #   EventBus.current.add_observer(self)
    #
    class EventBus
      # Get the event bus for the current thread.
      # Raises if no bus has been set up.
      #
      # @return [EventBus]
      def self.current
        Thread.current[:rspec_agents_event_bus] or
          raise "No EventBus set for current thread. Call EventBus.current = EventBus.new first."
      end

      # Set the event bus for the current thread.
      #
      # @param bus [EventBus, nil]
      def self.current=(bus)
        Thread.current[:rspec_agents_event_bus] = bus
      end

      # Check whether an event bus has been set for the current thread.
      #
      # @return [Boolean]
      def self.current?
        !Thread.current[:rspec_agents_event_bus].nil?
      end

      def initialize
        @subscribers = Hash.new { |h, k| h[k] = [] }
        @global_subscribers = []
        @mutex = Mutex.new
      end

      # Subscribe to specific event types or all events (if no types given)
      #
      # @param event_types [Array<Class>] Event classes to subscribe to
      # @yield [event] Handler block called when event is published
      # @return [self]
      def subscribe(*event_types, &handler)
        @mutex.synchronize do
          if event_types.empty?
            @global_subscribers << handler
          else
            event_types.each { |type| @subscribers[type] << handler }
          end
        end
        self
      end

      # Publish an event to all relevant subscribers
      # Errors in subscribers are logged but do not propagate
      #
      # @param event [Object] The event to publish
      def publish(event)
        return if event.nil?

        handlers = @mutex.synchronize do
          @global_subscribers + @subscribers[event.class]
        end

        handlers.each do |handler|
          handler.call(event)
        rescue => e
          warn "[RSpec::Agents::EventBus] Observer error: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).map { |l| "  #{l}" }.join("\n") if ENV["DEBUG"]
        end
      end

      # Register an observer object that responds to on_* methods
      # Method names are derived from event class names (e.g., UserMessage -> on_user_message)
      #
      # @param observer [Object] Observer with on_* methods
      # @return [self]
      def add_observer(observer)
        subscribe do |event|
          method_name = "on_#{underscore(event.class.name.split("::").last)}"
          observer.send(method_name, event) if observer.respond_to?(method_name)
        end
      end

      # Clear all subscriptions (for testing or between runs)
      def clear!
        @mutex.synchronize do
          @subscribers.clear
          @global_subscribers.clear
        end
      end

      private

      def underscore(camel_case)
        camel_case.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end

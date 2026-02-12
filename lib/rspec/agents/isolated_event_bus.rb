# frozen_string_literal: true

module RSpec
  module Agents
    # Isolated EventBus for worker processes or testing.
    # Same interface as EventBus but not a singleton - each instance is independent.
    #
    # Use this when you need:
    # - Multiple isolated event buses (e.g., parallel workers)
    # - Test isolation without clearing the singleton
    # - Custom event routing per context
    #
    # @example Worker process
    #   event_bus = IsolatedEventBus.new
    #   Thread.current[:rspec_agents_event_bus] = event_bus
    #   observer = MyObserver.new(event_bus: event_bus)
    #
    class IsolatedEventBus
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
          warn "[IsolatedEventBus] Observer error: #{e.class}: #{e.message}"
        end
      end

      # Register an observer object that responds to on_* methods
      # Method names are derived from event class names (e.g., UserMessage -> on_user_message)
      #
      # @param observer [Object] Observer with on_* methods
      # @return [self]
      def add_observer(observer)
        subscribe do |event|
          method_name = "on_#{underscore(event.class.name.split('::').last)}"
          observer.send(method_name, event) if observer.respond_to?(method_name)
        end
      end

      # Clear all subscriptions
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

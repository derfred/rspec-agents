# frozen_string_literal: true

module RSpec
  module Agents
    module Observers
      # Base class for event observers.
      # Subclasses override on_* methods to handle specific events.
      #
      # This provides a unified interface for observing both RSpec lifecycle
      # events and conversation events.
      #
      # @example Custom observer
      #   class MyObserver < Observers::Base
      #     def on_example_started(event)
      #       puts "Starting: #{event.description}"
      #     end
      #
      #     def on_user_message(event)
      #       puts "User said: #{event.text}"
      #     end
      #   end
      #
      class Base
        def initialize(event_bus: EventBus.instance)
          event_bus.add_observer(self)
        end

        # =======================================================================
        # RSpec Suite Lifecycle
        # =======================================================================

        def on_suite_started(event); end
        def on_suite_stopped(event); end
        def on_suite_summary(event); end

        # =======================================================================
        # RSpec Group Lifecycle (describe/context blocks)
        # =======================================================================

        def on_group_started(event); end
        def on_group_finished(event); end

        # =======================================================================
        # RSpec Example Lifecycle
        # =======================================================================

        def on_example_started(event); end
        def on_example_passed(event); end
        def on_example_failed(event); end
        def on_example_pending(event); end

        # =======================================================================
        # Simulation Lifecycle
        # =======================================================================

        def on_simulation_started(event); end
        def on_simulation_ended(event); end

        # =======================================================================
        # Conversation Turn Events
        # =======================================================================

        def on_user_message(event); end
        def on_agent_response(event); end
        def on_topic_changed(event); end
        def on_tool_call_completed(event); end
      end
    end
  end
end

# frozen_string_literal: true

require "json"

module RSpec
  module Agents
    module Observers
      # Bridges EventBus events to RPC notifications
      # Subscribes to all events and forwards them as JSON to the RPC output
      class RpcNotifyObserver
        # @param rpc_output [IO] Output stream for RPC notifications (socket or stdout)
        # @param event_bus [EventBus] Event bus to subscribe to
        def initialize(rpc_output:, event_bus:)
          @rpc_output = rpc_output
          @mutex = Mutex.new

          # Subscribe to all events
          event_bus.subscribe { |event| forward_event(event) }
        end

        private

        def forward_event(event)
          event_type = event.class.name.split("::").last
          payload = event.to_h

          notification = {
            type:       "event",
            event_type: event_type,
            payload:    payload
          }

          @mutex.synchronize do
            @rpc_output.puts(notification.to_json)
            @rpc_output.flush
          end
        rescue IOError, Errno::EPIPE
          # Channel closed, ignore
        end
      end
    end
  end
end

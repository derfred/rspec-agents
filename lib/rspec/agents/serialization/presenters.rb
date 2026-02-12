# frozen_string_literal: true

module RSpec
  module Agents
    module Serialization
      # Presenters for HTML templates - wrap Serialization data classes
      # to provide template-friendly access patterns

      class DataPresenter
        def initialize(data)
          @data = data
        end

        def method_missing(method, *args, &block)
          if @data.respond_to?(method)
            @data.public_send(method, *args, &block)
          else
            super
          end
        end

        def respond_to_missing?(method, include_private = false)
          @data.respond_to?(method) || super
        end

        def [](key)
          @data.respond_to?(key) ? @data.public_send(key) : nil
        end

        def empty?
          false
        end
      end

      class ExceptionPresenter < DataPresenter
        def [](key)
          case key
          when :class then @data.class_name
          when :message then @data.message
          when :backtrace then @data.backtrace
          else
            super
          end
        end
      end

      class MessagePresenter < DataPresenter
        attr_reader :tool_calls_data

        def initialize(data, tool_calls: nil)
          super(data)
          @tool_calls_data = tool_calls
        end

        def [](key)
          case key.to_sym
          when :role then @data.role
          when :content then @data.content
          when :timestamp then parsed_timestamp
          when :tool_calls then formatted_tool_calls
          when :metadata then metadata_hash
          else
            super
          end
        end

        def role
          @data.role
        end

        def content
          @data.content
        end

        def timestamp
          parsed_timestamp
        end

        def tool_calls
          formatted_tool_calls
        end

        def metadata
          metadata_hash
        end

        private

        def parsed_timestamp
          ts = @data.timestamp
          return ts if ts.is_a?(Time)
          return nil unless ts

          # Parse ISO8601 string back to Time
          Time.parse(ts.to_s) rescue ts
        end

        def metadata_hash
          meta = @data.metadata
          hash = meta.respond_to?(:to_h) ? meta.to_h : (meta || {})
          hash.respond_to?(:with_indifferent_access) ? hash.with_indifferent_access : hash
        end

        def formatted_tool_calls
          return nil unless @tool_calls_data&.any?

          @tool_calls_data.map do |tc|
            {
              name:      tc.name,
              arguments: tc.arguments,
              result:    tc.result,
              error:     tc.error
            }
          end
        end
      end

      class EvaluationPresenter < DataPresenter
        def [](key)
          case key
          when :name then @data.name
          when :description then @data.description
          when :satisfied then @data.passed
          when :reasoning then @data.reasoning
          else
            super
          end
        end

        def name
          @data.name
        end

        def description
          @data.description
        end

        def satisfied?
          @data.passed
        end

        def satisfied
          @data.passed
        end

        def reasoning
          @data.reasoning
        end

        def to_h
          {
            name:        @data.name,
            description: @data.description,
            satisfied:   @data.passed,
            reasoning:   @data.reasoning
          }
        end
      end

      class ExamplePresenter < DataPresenter
        def [](key)
          case key
          when :id then @data.id
          when :description then @data.description
          when :status then @data.status
          when :duration then duration_in_seconds
          when :exception then exception_presenter
          when :messages then messages_from_conversation
          when :criterion_results then evaluation_presenters
          else
            super
          end
        end

        def example_id
          @data.id
        end

        def description
          @data.description
        end

        def location
          @data.location
        end

        def file_path
          @data.location&.split(":")&.first
        end

        def line_number
          @data.location&.split(":")&.last&.to_i
        end

        def status
          @data.status
        end

        def duration
          duration_in_seconds
        end

        def exception
          exception_presenter
        end

        def messages
          messages_from_conversation
        end

        def criterion_results
          evaluation_presenters
        end

        def conversation
          @data.conversation
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        def to_h
          {
            example_id:        @data.id,
            description:       @data.description,
            location:          @data.location,
            file_path:         file_path,
            line_number:       line_number,
            status:            @data.status,
            duration:          duration_in_seconds,
            exception:         @data.exception&.to_h,
            messages:          messages_as_hashes,
            criterion_results: evaluation_presenters.map(&:to_h)
          }
        end

        private

        def duration_in_seconds
          @data.duration_ms ? @data.duration_ms / 1000.0 : 0.0
        end

        def exception_presenter
          @exception_presenter ||= @data.exception ? ExceptionPresenter.new(@data.exception) : nil
        end

        def messages_from_conversation
          @messages ||= flatten_conversation
        end

        def flatten_conversation
          return [] unless @data.conversation

          @data.conversation.turns.flat_map do |turn|
            msgs = []
            msgs << MessagePresenter.new(turn.user_message) if turn.user_message
            msgs << MessagePresenter.new(turn.agent_response, tool_calls: turn.tool_calls) if turn.agent_response
            msgs
          end
        end

        def messages_as_hashes
          messages_from_conversation.map do |msg|
            {
              role:       msg.role,
              content:    msg.content,
              timestamp:  msg.timestamp,
              tool_calls: msg.tool_calls,
              metadata:   msg.metadata
            }
          end
        end

        def evaluation_presenters
          @evaluation_presenters ||= (@data.evaluations || []).map { |e| EvaluationPresenter.new(e) }
        end
      end
    end
  end
end

# frozen_string_literal: true

module RSpec
  module Agents
    # Shared backtrace extraction and filtering for spec executors.
    # Included by SpecExecutor (sequential) and HeadlessRunner (parallel worker).
    module BacktraceHelper
      MAX_BACKTRACE_LINES = 10

      def extract_failure_message(notification)
        if notification.respond_to?(:exception) && notification.exception
          notification.exception.message
        elsif notification.example.execution_result.exception
          notification.example.execution_result.exception.message
        end
      end

      def extract_backtrace(notification)
        backtrace = if notification.respond_to?(:formatted_backtrace)
                      notification.formatted_backtrace
                    elsif notification.example.execution_result.exception
                      notification.example.execution_result.exception.backtrace
                    end
        filter_backtrace(backtrace)
      end

      def filter_backtrace(backtrace)
        return nil unless backtrace

        app_path = File.expand_path(Dir.getwd)
        filtered = backtrace.select { |line|
          # Extract the file path portion (before the first colon, e.g. "/path/to/file.rb:42")
          file_path = line.split(":").first
          expanded = File.expand_path(file_path) rescue file_path
          expanded.start_with?(app_path)
        }.first(MAX_BACKTRACE_LINES)

        # If nothing matched (e.g. formatted_backtrace already filtered), use as-is
        filtered.empty? ? backtrace.first(MAX_BACKTRACE_LINES) : filtered
      end
    end
  end
end

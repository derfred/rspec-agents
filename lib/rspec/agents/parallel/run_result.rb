# frozen_string_literal: true

module RSpec
  module Agents
    module Parallel
      # Immutable result from a parallel spec run
      RunResult = Data.define(:success, :example_count, :failure_count, :completed_examples, :error) do
        def initialize(success:, example_count: 0, failure_count: 0, completed_examples: [], error: nil)
          super
        end

        def success?
          success
        end

        def failed?
          !success
        end
      end
    end
  end
end

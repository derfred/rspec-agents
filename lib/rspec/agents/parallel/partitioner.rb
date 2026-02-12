# frozen_string_literal: true

module RSpec
  module Agents
    module Parallel
      # Distributes examples across workers using round-robin assignment
      class Partitioner
        def self.partition(examples, worker_count)
          new.partition(examples, worker_count)
        end

        # Partition examples across workers
        #
        # @param examples [Array<ExampleRef>] Examples to distribute
        # @param worker_count [Integer] Number of workers
        # @return [Array<Array<ExampleRef>>] Array of arrays, one per worker
        def partition(examples, worker_count)
          return [[]] if examples.empty? || worker_count <= 0

          partitions = Array.new(worker_count) { [] }

          examples.each_with_index do |example, i|
            partitions[i % worker_count] << example
          end

          partitions
        end
      end
    end
  end
end

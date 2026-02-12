# frozen_string_literal: true

module RSpec
  module Agents
    module Serialization
      # Computes aggregate statistics from RunData for display in HTML reports.
      #
      # @example Basic usage
      #   aggregator = RunDataAggregator.new(run_data)
      #   stats = aggregator.aggregation_data
      #   summary = aggregator.summary_data(presented_examples)
      #
      class RunDataAggregator
        attr_reader :run_data

        # @param run_data [RunData] the test run data to aggregate
        def initialize(run_data)
          @run_data = run_data
        end

        # Compute aggregation data for the summary cards.
        #
        # @return [Hash] aggregation statistics
        def aggregation_data
          examples = @run_data.examples.values

          {
            completion: compute_completion_stats(examples),
            quality:    compute_quality_stats(examples),
            efficiency: compute_efficiency_stats(examples),
            scenarios:  compute_scenario_stats(examples)
          }
        end

        # Compute summary data for the summary table.
        #
        # @param presented_examples [Array<ExamplePresenter>] presented example data
        # @return [Hash] summary table data
        def summary_data(presented_examples)
          all_criterion_names = presented_examples.flat_map do |example|
            (example[:criterion_results] || []).map { |cr| cr[:name] }
          end.uniq.sort

          summary_rows = presented_examples.map do |example|
            build_summary_row(example)
          end

          {
            criterion_names: all_criterion_names,
            rows:            summary_rows
          }
        end

        private

        def compute_completion_stats(examples)
          total = examples.size
          passed = examples.count { |e| e.status == :passed }
          failed = examples.count { |e| e.status == :failed }
          pending = examples.count { |e| e.status == :pending }
          rate = total > 0 ? (passed.to_f / total * 100).round(1) : 0.0

          {
            total:     total,
            passed:    passed,
            failed:    failed,
            pending:   pending,
            rate:      rate,
            breakdown: compute_failure_breakdown(examples)
          }
        end

        def compute_failure_breakdown(examples)
          failed_examples = examples.select { |e| e.status == :failed }
          breakdown = { assertion: 0, max_turns: 0, error: 0 }

          failed_examples.each do |example|
            if example.exception
              msg = example.exception.message.to_s.downcase
              if msg.include?("max") && msg.include?("turn")
                breakdown[:max_turns] += 1
              elsif example.evaluations&.any? { |ev| ev.hard? && !ev.passed }
                breakdown[:assertion] += 1
              else
                breakdown[:error] += 1
              end
            else
              breakdown[:assertion] += 1
            end
          end

          breakdown
        end

        def compute_quality_stats(examples)
          all_evaluations = examples.flat_map { |e| e.evaluations || [] }

          total_evals = all_evaluations.size
          passed_evals = all_evaluations.count(&:passed)
          rate = total_evals > 0 ? (passed_evals.to_f / total_evals * 100).round(1) : 0.0

          {
            total_evals:  total_evals,
            passed_evals: passed_evals,
            rate:         rate,
            by_criterion: compute_criteria_stats(all_evaluations)
          }
        end

        def compute_criteria_stats(evaluations)
          stats = {}

          evaluations.each do |eval|
            name = eval.name
            stats[name] ||= { evaluated: 0, passed: 0 }
            stats[name][:evaluated] += 1
            stats[name][:passed] += 1 if eval.passed
          end

          stats.each do |_name, data|
            data[:rate] = data[:evaluated] > 0 ? (data[:passed].to_f / data[:evaluated] * 100).round(1) : 0.0
          end

          stats.sort_by { |name, _| name.to_s }.to_h
        end

        def compute_efficiency_stats(examples)
          turn_counts = examples.filter_map do |example|
            example.conversation&.turns&.size
          end

          if turn_counts.empty?
            return { avg_turns: 0.0, median_turns: 0, turn_range: "0-0" }
          end

          sorted = turn_counts.sort
          avg = (turn_counts.sum.to_f / turn_counts.size).round(1)
          median = sorted[sorted.size / 2]
          range_str = "#{sorted.first}-#{sorted.last}"

          {
            avg_turns:    avg,
            median_turns: median,
            turn_range:   range_str
          }
        end

        def compute_scenario_stats(examples)
          return [] if @run_data.scenarios.empty?

          examples_by_scenario = examples.group_by(&:scenario_id)

          @run_data.scenarios.values.map do |scenario|
            scenario_examples = examples_by_scenario[scenario.id] || []
            total = scenario_examples.size
            passed = scenario_examples.count { |e| e.status == :passed }

            {
              id:     scenario.id,
              name:   scenario.name || scenario.id,
              total:  total,
              passed: passed,
              rate:   total > 0 ? (passed.to_f / total * 100).round(1) : 0.0
            }
          end.sort_by { |s| s[:name].to_s }
        end

        def build_summary_row(example)
          has_generic_error = example[:exception] &&
                              (example[:criterion_results].nil? || example[:criterion_results].empty?)

          criterion_map = {}
          (example[:criterion_results] || []).each do |cr|
            criterion_map[cr[:name]] = {
              satisfied: cr[:satisfied],
              reasoning: cr[:reasoning]
            }
          end

          exception_summary = if has_generic_error && example[:exception]
                                "#{example[:exception][:class]}: #{example[:exception][:message]}"
                              end

          {
            id:                example[:id],
            description:       example[:description],
            status:            example[:status],
            duration:          example[:duration],
            has_generic_error: has_generic_error,
            exception_summary: exception_summary,
            criterion_map:     criterion_map
          }
        end
      end
    end
  end
end

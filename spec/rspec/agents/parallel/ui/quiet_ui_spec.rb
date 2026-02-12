require "spec_helper"
require "rspec/agents"
require "stringio"

RSpec.describe RSpec::Agents::Parallel::UI::QuietUI do
  let(:output) { StringIO.new }
  let(:time) { Time.now }
  let(:ui) { described_class.new(output: output, color: false) }

  describe "#on_run_started" do
    it "prints header" do
      ui.on_run_started(worker_count: 4, example_count: 10)

      expect(output.string).to include("Parallel spec runner")
      expect(output.string).to include("4 workers")
    end
  end

  describe "#on_example_finished" do
    before { ui.on_run_started(worker_count: 2, example_count: 5) }

    it "prints dot for passing examples" do
      event = RSpec::Agents::Events::ExamplePassed.new(
        example_id: "test1", stable_id: nil,
        description: "passes", full_description: "passes",
        duration: 0.1, time: time
      )

      ui.on_example_finished(worker: 0, event: event)

      expect(output.string).to include(".")
    end

    it "prints F for failing examples" do
      event = RSpec::Agents::Events::ExampleFailed.new(
        example_id: "test1", stable_id: nil,
        description: "fails", full_description: "fails",
        location: "spec/test_spec.rb:1",
        duration: 0.1, message: "Error", backtrace: [],
        time: time
      )

      ui.on_example_finished(worker: 0, event: event)

      expect(output.string).to include("F")
      expect(ui.failures).to include(event)
    end

    it "prints * for pending examples" do
      event = RSpec::Agents::Events::ExamplePending.new(
        example_id: "test1", stable_id: nil,
        description: "pending", full_description: "pending",
        message: "Not yet", time: time
      )

      ui.on_example_finished(worker: 0, event: event)

      expect(output.string).to include("*")
    end

    it "wraps at 50 characters" do
      55.times do |i|
        event = RSpec::Agents::Events::ExamplePassed.new(
          example_id: "test#{i}", stable_id: nil,
          description: "test", full_description: "test",
          duration: 0.01, time: time
        )
        ui.on_example_finished(worker: 0, event: event)
      end

      lines = output.string.lines
      # Should have wrapped after 50 dots
      dot_lines = lines.select { |l| l.match?(/^[.F*E]+$/) }
      expect(dot_lines.first&.strip&.length).to eq(50)
    end
  end
end

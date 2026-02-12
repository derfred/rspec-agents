require "spec_helper"
require "rspec/agents"
require "stringio"

RSpec.describe RSpec::Agents::Parallel::UI::UIFactory do
  let(:tty_output) do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(true)
    output
  end

  let(:non_tty_output) do
    output = StringIO.new
    allow(output).to receive(:tty?).and_return(false)
    output
  end

  describe ".create" do
    it "creates InteractiveUI for explicit :interactive mode" do
      ui = described_class.create(mode: :interactive, output: non_tty_output)
      expect(ui).to be_a(RSpec::Agents::Parallel::UI::InteractiveUI)
    end

    it "creates InterleavedUI for explicit :interleaved mode" do
      ui = described_class.create(mode: :interleaved, output: tty_output)
      expect(ui).to be_a(RSpec::Agents::Parallel::UI::InterleavedUI)
    end

    it "creates QuietUI for explicit :quiet mode" do
      ui = described_class.create(mode: :quiet, output: tty_output)
      expect(ui).to be_a(RSpec::Agents::Parallel::UI::QuietUI)
    end

    it "creates InterleavedUI for non-TTY output by default" do
      ui = described_class.create(output: non_tty_output)
      expect(ui).to be_a(RSpec::Agents::Parallel::UI::InterleavedUI)
    end

    it "auto-detects color from TTY" do
      ui = described_class.create(output: tty_output)
      expect(ui.instance_variable_get(:@color)).to be true

      ui2 = described_class.create(output: non_tty_output)
      expect(ui2.instance_variable_get(:@color)).to be false
    end

    it "respects explicit color setting" do
      ui = described_class.create(output: tty_output, color: false)
      expect(ui.instance_variable_get(:@color)).to be false

      ui2 = described_class.create(output: non_tty_output, color: true)
      expect(ui2.instance_variable_get(:@color)).to be true
    end
  end
end

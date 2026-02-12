require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::Parallel::UI::UIMode do
  describe ".select" do
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

    context "with explicit mode" do
      it "returns the explicit mode when valid" do
        expect(described_class.select(explicit_mode: :interactive, output: non_tty_output)).to eq(:interactive)
        expect(described_class.select(explicit_mode: :interleaved, output: tty_output)).to eq(:interleaved)
        expect(described_class.select(explicit_mode: :quiet, output: tty_output)).to eq(:quiet)
      end

      it "ignores invalid explicit modes" do
        expect(described_class.select(explicit_mode: :invalid, output: tty_output)).not_to eq(:invalid)
      end
    end

    context "auto-detection" do
      it "selects interleaved for non-TTY output" do
        expect(described_class.select(output: non_tty_output)).to eq(:interleaved)
      end

      it "selects interleaved when CI environment variable is set" do
        original_ci = ENV["CI"]
        ENV["CI"] = "true"

        expect(described_class.select(output: tty_output)).to eq(:interleaved)
      ensure
        if original_ci
          ENV["CI"] = original_ci
        else
          ENV.delete("CI")
        end
      end

      it "selects interleaved when GITHUB_ACTIONS is set" do
        original = ENV["GITHUB_ACTIONS"]
        ENV["GITHUB_ACTIONS"] = "true"

        expect(described_class.select(output: tty_output)).to eq(:interleaved)
      ensure
        if original
          ENV["GITHUB_ACTIONS"] = original
        else
          ENV.delete("GITHUB_ACTIONS")
        end
      end
    end

    describe ".parse" do
      it "parses valid mode strings" do
        expect(described_class.parse("interactive")).to eq(:interactive)
        expect(described_class.parse("interleaved")).to eq(:interleaved)
        expect(described_class.parse("quiet")).to eq(:quiet)
      end

      it "returns nil for invalid mode strings" do
        expect(described_class.parse("invalid")).to be_nil
        expect(described_class.parse(nil)).to be_nil
      end
    end

    describe ".ci_environment?" do
      it "detects CI environment variable" do
        original = ENV["CI"]
        ENV["CI"] = "true"
        expect(described_class.ci_environment?).to be true
      ensure
        if original
          ENV["CI"] = original
        else
          ENV.delete("CI")
        end
      end

      it "returns false when no CI variables set" do
        originals = { "CI" => ENV["CI"], "CONTINUOUS_INTEGRATION" => ENV["CONTINUOUS_INTEGRATION"], "GITHUB_ACTIONS" => ENV["GITHUB_ACTIONS"] }

        ENV.delete("CI")
        ENV.delete("CONTINUOUS_INTEGRATION")
        ENV.delete("GITHUB_ACTIONS")

        expect(described_class.ci_environment?).to be false
      ensure
        originals.each do |k, v|
          if v
            ENV[k] = v
          else
            ENV.delete(k)
          end
        end
      end
    end
  end
end

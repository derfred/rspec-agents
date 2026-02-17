# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"

# End-to-end integration test for the rspec-agents binary.
#
# Exercises the full pipeline: CLI → spec discovery → agent execution →
# conversation tracking → JSON/HTML output. Uses a self-contained fixture
# spec with a mock agent so no external network calls are required.
RSpec.describe "End-to-end integration", type: :integration do
  let(:project_root) { File.expand_path("../../..", __dir__) }
  let(:binary)       { File.join(project_root, "bin", "rspec-agents") }
  let(:fixture_src)  { File.join(project_root, "spec", "fixtures", "e2e_agent_fixture.rb") }
  let(:temp_dir)     { Dir.mktmpdir("rspec_agents_e2e") }

  after { FileUtils.rm_rf(temp_dir) }

  # Copy the fixture into the temp directory as a _spec.rb so the binary
  # discovers it.  Returns the path to the copied file.
  def install_fixture
    dest = File.join(temp_dir, "spec")
    FileUtils.mkdir_p(dest)
    target = File.join(dest, "e2e_agent_spec.rb")
    FileUtils.cp(fixture_src, target)
    target
  end

  # Run the rspec-agents binary with the given extra arguments.
  # Returns [stdout, stderr, Process::Status, json_path, html_path].
  def run_binary(*extra_args)
    spec_path = install_fixture
    json_path = File.join(temp_dir, "output", "results.json")
    html_path = File.join(temp_dir, "output", "report.html")

    cmd = [
      RbConfig.ruby, binary,
      *extra_args,
      "--no-color",
      "--json", json_path,
      "--html", html_path,
      spec_path
    ]

    env = {
      "BUNDLE_GEMFILE" => File.join(project_root, "Gemfile"),
      "HOME" => ENV["HOME"]
    }

    stdout, stderr, status = Open3.capture3(env, *cmd, chdir: project_root)
    [stdout, stderr, status, json_path, html_path]
  end

  # ------------------------------------------------------------------
  # Shared assertions for JSON and HTML output, used by both modes.
  # ------------------------------------------------------------------
  shared_examples "produces correct output files" do |mode_label|
    it "exits successfully" do
      expect(status).to be_success,
        "Expected exit 0 for #{mode_label}, got #{status.exitstatus}.\nSTDERR:\n#{stderr}"
    end

    it "creates a valid JSON output file with conversation data" do
      expect(File.exist?(json_path)).to be(true),
        "JSON output file not found at #{json_path}"

      data = JSON.parse(File.read(json_path))
      expect(data).to have_key("examples")
      expect(data["examples"].size).to be >= 2 # at least our two fixture examples

      # Verify that conversation data is present in every example
      data["examples"].each_value do |ex|
        expect(ex).to have_key("conversation"),
          "Example '#{ex["description"]}' missing conversation data"
        conversation = ex["conversation"]
        expect(conversation).to have_key("turns")
      end

      # The multi-turn booking example should have 4 turns
      booking_example = data["examples"].values.find { |ex| ex["description"].include?("multi-turn") }
      expect(booking_example).not_to be_nil, "Could not find multi-turn booking example in JSON"
      expect(booking_example["conversation"]["turns"].size).to eq(4)

      # Verify user/agent message content round-trips through serialization
      first_turn = booking_example["conversation"]["turns"][0]
      expect(first_turn["user_message"]["content"]).to include("help planning")
      expect(first_turn["agent_response"]["content"]).to include("Hello")

      # Verify tool call data is serialized
      venue_turn = booking_example["conversation"]["turns"].find do |t|
        t["tool_calls"]&.any? { |tc| tc["name"] == "search_venues" }
      end
      expect(venue_turn).not_to be_nil, "Expected a turn with search_venues tool call"
      expect(venue_turn["tool_calls"][0]["arguments"]).to have_key("query")

      # Verify evaluations are present
      eval_example = data["examples"].values.find { |ex| ex["description"].include?("evaluations") }
      expect(eval_example).not_to be_nil, "Could not find evaluation example in JSON"
      expect(eval_example["evaluations"].size).to eq(2)
      modes = eval_example["evaluations"].map { |e| e["mode"] }
      expect(modes).to include("hard")
      expect(modes).to include("soft")
    end

    it "creates an HTML report file" do
      expect(File.exist?(html_path)).to be(true),
        "HTML output file not found at #{html_path}"

      html = File.read(html_path)
      expect(html).to include("<html")
      expect(html.length).to be > 500,
        "HTML file seems too small to be a proper report (#{html.length} bytes)"
    end
  end

  # ====================================================================
  # Sequential mode (default)
  # ====================================================================
  describe "sequential mode" do
    let(:result)    { run_binary }
    let(:stdout)    { result[0] }
    let(:stderr)    { result[1] }
    let(:status)    { result[2] }
    let(:json_path) { result[3] }
    let(:html_path) { result[4] }

    include_examples "produces correct output files", "sequential"

    it "prints lifecycle events to stdout" do
      expect(stdout).to include("Suite started")
      expect(stdout).to include("examples")
      expect(stdout).to include("0 failures")
    end
  end

  # ====================================================================
  # Parallel mode (-w workers)
  # ====================================================================
  describe "parallel mode" do
    let(:result)    { run_binary("-w", "2", "--ui", "interleaved") }
    let(:stdout)    { result[0] }
    let(:stderr)    { result[1] }
    let(:status)    { result[2] }
    let(:json_path) { result[3] }
    let(:html_path) { result[4] }

    include_examples "produces correct output files", "parallel"

    it "prints conversation log to stdout" do
      # The interleaved UI prints User: / Agent: lines for conversation events
      combined = stdout + stderr
      expect(combined).to include("User:"),
        "Expected conversation User: line in parallel output.\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
      expect(combined).to include("Agent:"),
        "Expected conversation Agent: line in parallel output.\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
    end
  end
end

# frozen_string_literal: true

require "spec_helper"
require "rspec/agents/serialization/conversation_renderer"
require "rspec/agents/serialization/extension"
require "rspec/agents/serialization/ir"

RSpec.describe RSpec::Agents::Serialization::ConversationRenderer do
  let(:now) { Time.now }

  let(:user_message) do
    RSpec::Agents::Serialization::MessageData.new(
      role: :user, content: "Hello", timestamp: now,
      metadata: { source: "test" }
    )
  end

  let(:agent_message) do
    RSpec::Agents::Serialization::MessageData.new(
      role: :agent, content: "Hi there!", timestamp: now + 1,
      metadata: { model: "test-model" }
    )
  end

  let(:tool_call) do
    RSpec::Agents::Serialization::ToolCallData.new(
      name: :search, arguments: { query: "test" }, timestamp: now,
      result: { found: true }
    )
  end

  let(:turn) do
    RSpec::Agents::Serialization::TurnData.new(
      number: 1, user_message: user_message, agent_response: agent_message,
      tool_calls: [tool_call]
    )
  end

  let(:conversation) do
    RSpec::Agents::Serialization::ConversationData.new(
      started_at: now, ended_at: now + 5, turns: [turn]
    )
  end

  # Extension that returns raw HTML strings from hooks
  let(:string_extension_class) do
    Class.new(RSpec::Agents::Serialization::Extension) do
      def template_dir
        File.expand_path("../templates", __dir__)
      end

      def priority
        10
      end

      def render_message_metadata(message, _message_id)
        "<div class='custom-meta'>Role: #{message[:role]}</div>"
      end
    end
  end

  # Extension that returns IR nodes from hooks via build_ir
  let(:ir_extension_class) do
    Class.new(RSpec::Agents::Serialization::Extension) do
      def template_dir
        File.expand_path("../templates", __dir__)
      end

      def priority
        20
      end

      def render_message_metadata(message, _message_id)
        build_ir do
          timestamp(message[:timestamp]) if message[:timestamp]

          if message[:tool_calls] && !message[:tool_calls].empty?
            tool_calls_section(message[:tool_calls])
          end
        end
      end
    end
  end

  # Extension that returns a single IR node hash (not wrapped in array)
  let(:single_node_extension_class) do
    Class.new(RSpec::Agents::Serialization::Extension) do
      def template_dir
        File.expand_path("../templates", __dir__)
      end

      def priority
        30
      end

      def render_message_metadata(message, _message_id)
        { type: "section", label: "Status", value: "ok" }
      end
    end
  end

  # Extension that raises an error
  let(:error_extension_class) do
    Class.new(RSpec::Agents::Serialization::Extension) do
      def template_dir
        File.expand_path("../templates", __dir__)
      end

      def priority
        40
      end

      def render_message_metadata(_message, _message_id)
        raise "Something broke"
      end
    end
  end

  describe "#render_extensions" do
    context "with String-returning extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [string_extension_class], example_id: "test_1")
      end

      it "passes through raw HTML strings" do
        message = renderer.messages.first
        html = renderer.render_extensions(:render_message_metadata, message, "test_1_msg_0")

        expect(html).to include("custom-meta")
        expect(html).to include("Role: user")
      end
    end

    context "with IR-returning extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [ir_extension_class], example_id: "test_1")
      end

      it "renders IR nodes to HTML" do
        agent_msg = renderer.messages.last
        html = renderer.render_extensions(:render_message_metadata, agent_msg, "test_1_msg_1")

        expect(html).to include("metadata-section")
        expect(html).to include("Timestamp")
        expect(html).to include("Tool Calls")
        expect(html).to include("search")
      end
    end

    context "with single Hash IR node extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [single_node_extension_class], example_id: "test_1")
      end

      it "wraps single Hash in array and renders" do
        message = renderer.messages.first
        html = renderer.render_extensions(:render_message_metadata, message, "test_1_msg_0")

        expect(html).to include("metadata-section")
        expect(html).to include("Status")
        expect(html).to include("ok")
      end
    end

    context "with mixed String and IR extensions" do
      subject(:renderer) do
        described_class.new(
          conversation,
          extensions: [string_extension_class, ir_extension_class],
          example_id: "test_1"
        )
      end

      it "renders both types concatenated" do
        message = renderer.messages.first
        html = renderer.render_extensions(:render_message_metadata, message, "test_1_msg_0")

        # String extension output
        expect(html).to include("custom-meta")
        # IR extension output
        expect(html).to include("Timestamp")
      end
    end

    context "with error-raising extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [error_extension_class], example_id: "test_1")
      end

      it "renders error message instead of crashing" do
        message = renderer.messages.first
        html = renderer.render_extensions(:render_message_metadata, message, "test_1_msg_0")

        expect(html).to include("extension-error")
        expect(html).to include("Something broke")
      end
    end
  end

  describe "#build_rendered_extensions" do
    context "with IR-returning extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [ir_extension_class], example_id: "test_1")
      end

      it "collects IR nodes for each message" do
        result = renderer.build_rendered_extensions

        expect(result).to have_key(:message_metadata)
        metadata = result[:message_metadata]

        # Both user and agent messages should have metadata
        expect(metadata).to have_key("test_1_msg_0")
        expect(metadata).to have_key("test_1_msg_1")
      end

      it "wraps nodes in versioned envelope" do
        result = renderer.build_rendered_extensions
        envelope = result[:message_metadata]["test_1_msg_0"]

        expect(envelope[:version]).to eq(1)
        expect(envelope[:nodes]).to be_an(Array)
        expect(envelope[:nodes].first[:type]).to eq("section")
      end

      it "includes tool calls for agent messages" do
        result = renderer.build_rendered_extensions
        agent_envelope = result[:message_metadata]["test_1_msg_1"]
        node_types = agent_envelope[:nodes].map { |n| n[:label] }

        expect(node_types).to include("Tool Calls")
      end
    end

    context "with String-returning extension" do
      subject(:renderer) do
        described_class.new(conversation, extensions: [string_extension_class], example_id: "test_1")
      end

      it "ignores String results (only collects IR nodes)" do
        result = renderer.build_rendered_extensions

        # String results are not IR data, so message_metadata should be empty
        expect(result[:message_metadata]).to be_empty
      end
    end

    context "with mixed String and IR extensions" do
      subject(:renderer) do
        described_class.new(
          conversation,
          extensions: [string_extension_class, ir_extension_class],
          example_id: "test_1"
        )
      end

      it "collects only IR nodes, ignores String results" do
        result = renderer.build_rendered_extensions
        envelope = result[:message_metadata]["test_1_msg_0"]

        # Only IR extension's nodes should be present
        expect(envelope[:nodes]).to be_an(Array)
        expect(envelope[:nodes].none? { |n| n[:type] == "raw_html" }).to be true
      end
    end
  end

  describe "#messages" do
    subject(:renderer) do
      described_class.new(conversation, extensions: [], example_id: "test_1")
    end

    it "flattens turns into message presenters" do
      messages = renderer.messages

      expect(messages.size).to eq(2)
      expect(messages[0].role).to eq("user")
      expect(messages[1].role).to eq("agent")
    end

    it "attaches tool calls to agent messages" do
      agent_msg = renderer.messages.last

      expect(agent_msg.tool_calls).to be_an(Array)
      expect(agent_msg.tool_calls.first[:name]).to eq("search")
    end
  end

  describe "#collect_message_classes" do
    let(:classes_extension_class) do
      Class.new(RSpec::Agents::Serialization::Extension) do
        def template_dir
          File.expand_path("../templates", __dir__)
        end

        def render_message_classes(_message, _message_id)
          { "highlighted" => "true", "selected" => "$store.foo.isSelected" }
        end
      end
    end

    subject(:renderer) do
      described_class.new(conversation, extensions: [classes_extension_class], example_id: "test_1")
    end

    it "collects Alpine class expressions from extensions" do
      message = renderer.messages.first
      classes = renderer.collect_message_classes(message, "test_1_msg_0")

      expect(classes).to eq({
        "highlighted" => "true",
        "selected" => "$store.foo.isSelected"
      })
    end
  end
end

RSpec.describe RSpec::Agents::Serialization::BaseRenderer do
  describe "#normalize_hook_result" do
    subject(:renderer) { described_class.new }

    # normalize_hook_result is private; test via send
    def normalize(result)
      renderer.send(:normalize_hook_result, result)
    end

    it "passes through String results" do
      expect(normalize("<div>hello</div>")).to eq("<div>hello</div>")
    end

    it "converts RenderResult to string" do
      rr = RSpec::Agents::Serialization::IR::RenderResult.new("<b>test</b>")
      expect(normalize(rr)).to eq("<b>test</b>")
    end

    it "renders Array of IR nodes to HTML" do
      nodes = [{ type: "section", label: "Test", value: "val" }]
      html = normalize(nodes)

      expect(html).to include("metadata-section")
      expect(html).to include("Test")
      expect(html).to include("val")
    end

    it "wraps single Hash IR node and renders to HTML" do
      node = { type: "section", label: "Single" }
      html = normalize(node)

      expect(html).to include("metadata-section")
      expect(html).to include("Single")
    end

    it "calls to_s on unknown types" do
      expect(normalize(42)).to eq("42")
    end
  end
end

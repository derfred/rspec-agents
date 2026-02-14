# frozen_string_literal: true

require "spec_helper"
require "rspec/agents/serialization/ir"

RSpec.describe RSpec::Agents::Serialization::IR do
  describe "VERSION" do
    it "is 1" do
      expect(described_class::VERSION).to eq(1)
    end
  end

  describe "TRUNCATE_LENGTH" do
    it "is 200" do
      expect(described_class::TRUNCATE_LENGTH).to eq(200)
    end
  end

  describe RSpec::Agents::Serialization::IR::Nodes do
    describe ".section" do
      it "creates a section with only label" do
        node = described_class.section(label: "Timestamp")
        expect(node).to eq({ type: "section", label: "Timestamp" })
      end

      it "creates a section with label and value" do
        node = described_class.section(label: "Timestamp", value: "2026-02-13T10:30:45Z")
        expect(node).to eq({ type: "section", label: "Timestamp", value: "2026-02-13T10:30:45Z" })
      end

      it "creates a section with badge" do
        node = described_class.section(label: "LLM Traces", badge: "3")
        expect(node).to eq({ type: "section", label: "LLM Traces", badge: "3" })
      end

      it "creates a section with language (code block)" do
        node = described_class.section(label: "Arguments", language: "json", value: '{"key": "val"}')
        expect(node).to eq({
          type: "section", label: "Arguments",
          language: "json", value: '{"key": "val"}'
        })
      end

      it "creates a section with children" do
        child = described_class.section(label: "Child")
        node = described_class.section(label: "Parent", children: [child])
        expect(node[:children]).to eq([{ type: "section", label: "Child" }])
      end

      it "strips nil values" do
        node = described_class.section(label: "Test", value: nil, badge: nil)
        expect(node.keys).to eq([:type, :label])
      end
    end

    describe ".table" do
      it "creates a table node" do
        node = described_class.table(headers: ["Name", "Status"], rows: [["foo", "ok"]])
        expect(node).to eq({
          type: "table",
          headers: ["Name", "Status"],
          rows: [["foo", "ok"]]
        })
      end
    end

    describe ".link" do
      it "creates a link node" do
        node = described_class.link(text: "View", url: "https://example.com")
        expect(node).to eq({
          type: "link",
          text: "View",
          url: "https://example.com"
        })
      end
    end

    describe ".raw_html" do
      it "creates a raw_html node" do
        node = described_class.raw_html(content: "<button>Click</button>")
        expect(node).to eq({ type: "raw_html", content: "<button>Click</button>" })
      end
    end

    describe ".envelope" do
      it "wraps nodes in a versioned envelope" do
        nodes = [described_class.section(label: "Test")]
        envelope = described_class.envelope(nodes)
        expect(envelope).to eq({
          version: 1,
          nodes: [{ type: "section", label: "Test" }]
        })
      end
    end
  end

  describe RSpec::Agents::Serialization::IR::RenderResult do
    it "wraps HTML string" do
      result = described_class.new("<div>hello</div>")
      expect(result.html).to eq("<div>hello</div>")
      expect(result.to_s).to eq("<div>hello</div>")
      expect(result.to_str).to eq("<div>hello</div>")
    end

    it "can be used in string interpolation" do
      result = described_class.new("<b>test</b>")
      expect("prefix: #{result}").to eq("prefix: <b>test</b>")
    end

    it "can be concatenated with strings" do
      result = described_class.new("<b>test</b>")
      expect("prefix " + result).to eq("prefix <b>test</b>")
    end
  end

  describe RSpec::Agents::Serialization::IR::HtmlRenderer do
    subject(:renderer) { described_class.new }

    describe "#render" do
      it "returns empty string for nil" do
        expect(renderer.render(nil)).to eq("")
      end

      it "returns empty string for empty array" do
        expect(renderer.render([])).to eq("")
      end

      context "section nodes" do
        it "renders a label-only section" do
          nodes = [{ type: "section", label: "Timestamp" }]
          html = renderer.render(nodes)
          expect(html).to include('class="metadata-section"')
          expect(html).to include('class="metadata-label"')
          expect(html).to include("Timestamp")
        end

        it "renders a label-value section" do
          nodes = [{ type: "section", label: "Timestamp", value: "2026-02-13" }]
          html = renderer.render(nodes)
          expect(html).to include('class="metadata-label"')
          expect(html).to include('class="metadata-value"')
          expect(html).to include("2026-02-13")
        end

        it "renders a section with badge" do
          nodes = [{ type: "section", label: "Traces", badge: "3" }]
          html = renderer.render(nodes)
          expect(html).to include('class="metadata-badge"')
          expect(html).to include("3")
        end

        it "renders a code block when language is set" do
          nodes = [{ type: "section", label: "Args", language: "json", value: '{"k":"v"}' }]
          html = renderer.render(nodes)
          expect(html).to include('class="metadata-code"')
          expect(html).to include('class="language-json"')
          expect(html).to include('{&quot;k&quot;:&quot;v&quot;}')
          expect(html).not_to include('class="metadata-value"')
        end

        it "renders children with expand/collapse Alpine bindings" do
          nodes = [{
            type: "section", label: "Parent",
            children: [{ type: "section", label: "Child", value: "val" }]
          }]
          html = renderer.render(nodes)
          expect(html).to include("expandable")
          expect(html).to include('class="metadata-children"')
          expect(html).to include("Child")
          expect(html).to include("val")
          expect(html).to include("data-ir-expandable")
          expect(html).to include("$store.expandable.toggle")
          expect(html).to include("x-show")
          expect(html).to include("ir-expandable-header")
        end

        it "escapes HTML in values" do
          nodes = [{ type: "section", label: "<script>", value: "<b>bold</b>" }]
          html = renderer.render(nodes)
          expect(html).to include("&lt;script&gt;")
          expect(html).to include("&lt;b&gt;bold&lt;/b&gt;")
        end

        context "text truncation" do
          it "does not truncate values under 200 characters" do
            short_value = "a" * 199
            nodes = [{ type: "section", label: "Short", value: short_value }]
            html = renderer.render(nodes)
            expect(html).not_to include("ir-truncated")
            expect(html).not_to include("ir-truncate-toggle")
            expect(html).not_to include("show more")
          end

          it "truncates values at exactly 200 characters" do
            exact_value = "a" * 200
            nodes = [{ type: "section", label: "Exact", value: exact_value }]
            html = renderer.render(nodes)
            expect(html).not_to include("ir-truncated")
          end

          it "truncates values over 200 characters" do
            long_value = "a" * 250
            nodes = [{ type: "section", label: "Long", value: long_value }]
            html = renderer.render(nodes)
            expect(html).to include("ir-truncated")
            expect(html).to include("data-ir-truncate")
            expect(html).to include("x-data")
            expect(html).to include("irExpanded")
            expect(html).to include("ir-truncate-toggle")
            expect(html).to include("show more")
            expect(html).to include("ir-ellipsis")
          end

          it "does not truncate code block values" do
            long_code = "x" * 300
            nodes = [{ type: "section", label: "Code", language: "json", value: long_code }]
            html = renderer.render(nodes)
            expect(html).not_to include("ir-truncated")
            expect(html).to include('class="metadata-code"')
          end
        end

        context "expand/collapse with children" do
          it "generates unique expandable IDs for multiple sections" do
            nodes = [
              { type: "section", label: "A", children: [{ type: "section", label: "A1" }] },
              { type: "section", label: "B", children: [{ type: "section", label: "B1" }] }
            ]
            html = renderer.render(nodes)
            expect(html).to include("ir_exp_1")
            expect(html).to include("ir_exp_2")
          end

          it "renders toggle arrow in expandable header" do
            nodes = [{
              type: "section", label: "Parent",
              children: [{ type: "section", label: "Child" }]
            }]
            html = renderer.render(nodes)
            expect(html).to include("expandable-toggle")
          end

          it "renders badge in expandable header" do
            nodes = [{
              type: "section", label: "Traces", badge: "5",
              children: [{ type: "section", label: "Trace 1" }]
            }]
            html = renderer.render(nodes)
            expect(html).to include("ir-expandable-header")
            expect(html).to include('class="metadata-badge"')
            expect(html).to include("5")
          end
        end
      end

      context "table nodes" do
        it "renders a table" do
          nodes = [{
            type: "table",
            headers: ["Name", "Status"],
            rows: [["search", "ok"], ["get", "error"]]
          }]
          html = renderer.render(nodes)
          expect(html).to include("<thead>")
          expect(html).to include("<th>Name</th>")
          expect(html).to include("<th>Status</th>")
          expect(html).to include("<td>search</td>")
          expect(html).to include("<td>ok</td>")
        end
      end

      context "link nodes" do
        it "renders a link" do
          nodes = [{ type: "link", text: "View", url: "https://example.com" }]
          html = renderer.render(nodes)
          expect(html).to include('href="https://example.com"')
          expect(html).to include(">View</a>")
          expect(html).to include('target="_blank"')
        end
      end

      context "raw_html nodes" do
        it "passes through raw HTML" do
          nodes = [{ type: "raw_html", content: "<button>Click</button>" }]
          html = renderer.render(nodes)
          expect(html).to eq("<button>Click</button>")
        end
      end

      context "unknown node types" do
        it "silently skips unknown types" do
          nodes = [{ type: "unknown_widget", data: "foo" }]
          html = renderer.render(nodes)
          expect(html).to eq("")
        end
      end

      context "mixed nodes" do
        it "renders multiple node types" do
          nodes = [
            { type: "section", label: "Timestamp", value: "2026-02-13" },
            { type: "table", headers: ["A"], rows: [["1"]] },
            { type: "link", text: "More", url: "https://example.com" }
          ]
          html = renderer.render(nodes)
          expect(html).to include("Timestamp")
          expect(html).to include("<table")
          expect(html).to include("href=")
        end
      end

      context "JSON round-trip" do
        it "renders nodes that went through JSON serialization" do
          nodes = [{ type: "section", label: "Test", value: "val" }]
          json_str = JSON.generate(nodes)
          parsed = JSON.parse(json_str, symbolize_names: true)
          html = renderer.render(parsed)
          expect(html).to include("Test")
          expect(html).to include("val")
        end
      end
    end
  end

  describe RSpec::Agents::Serialization::IR::Builder do
    describe "with extension delegation" do
      let(:extension) do
        ext = double("extension")
        allow(ext).to receive(:respond_to?).and_return(false)
        allow(ext).to receive(:respond_to?).with(:render_template, true).and_return(true)
        allow(ext).to receive(:render_template).and_return(
          RSpec::Agents::Serialization::IR::RenderResult.new("<div>template</div>")
        )
        ext
      end

      it "delegates render_template to extension and auto-inserts raw_html" do
        builder = described_class.new(extension: extension)
        builder.instance_eval do
          section("Heading")
          render_template("_widget.html.haml")
        end

        expect(builder.nodes.size).to eq(2)
        expect(builder.nodes[0][:type]).to eq("section")
        expect(builder.nodes[1][:type]).to eq("raw_html")
        expect(builder.nodes[1][:content]).to eq("<div>template</div>")
      end

      it "inserts raw_html inside a section with children" do
        builder = described_class.new(extension: extension)
        builder.instance_eval do
          section("Parent") do
            section("Child")
            render_template("_widget.html.haml")
          end
        end

        parent = builder.nodes[0]
        expect(parent[:children].size).to eq(2)
        expect(parent[:children][1][:type]).to eq("raw_html")
      end
    end

    describe "without extension" do
      it "raises NoMethodError for unknown methods" do
        builder = described_class.new
        expect {
          builder.instance_eval { render_template("test") }
        }.to raise_error(NoMethodError)
      end
    end
  end
end

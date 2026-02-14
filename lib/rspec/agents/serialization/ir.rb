# frozen_string_literal: true

require "json"
require "cgi"

module RSpec
  module Agents
    module Serialization
      # Intermediate Representation (IR) for conversation rendering.
      #
      # The IR is a JSON-serializable data structure that describes *what* to render
      # using a fixed vocabulary of node types. Extensions produce IR on the runner
      # side (where Ruby is available), and it can be rendered to HTML locally or
      # consumed as JSON by a hosted frontend.
      #
      # Node types: section, table, link, raw_html
      # See docs/conversation-rendering-ir.md for full specification.
      module IR
        VERSION = 1

        # Factory methods for creating IR node hashes.
        # Each method returns a plain Hash with nil values stripped.
        module Nodes
          module_function

          # Create a section node — the universal container.
          #
          # @param label [String] section heading (required)
          # @param value [String, nil] inline text value
          # @param badge [String, nil] small pill shown after the label
          # @param language [String, nil] when set, value is rendered as a code block
          # @param children [Array, nil] nested nodes (makes section expandable)
          # @return [Hash]
          def section(label:, value: nil, badge: nil, language: nil, children: nil)
            node = { type: "section", label: label }
            node[:value] = value if value
            node[:badge] = badge if badge
            node[:language] = language if language
            node[:children] = children if children
            node
          end

          # Create a table node.
          #
          # @param headers [Array<String>] column headers
          # @param rows [Array<Array<String>>] row data
          # @return [Hash]
          def table(headers:, rows:)
            { type: "table", headers: headers, rows: rows }
          end

          # Create a link node.
          #
          # @param text [String] link text
          # @param url [String] link URL
          # @return [Hash]
          def link(text:, url:)
            { type: "link", text: text, url: url }
          end

          # Create a raw_html node (escape hatch).
          # Rendered only in local/runner mode. Dropped in hosted mode.
          #
          # @param content [String] raw HTML content
          # @return [Hash]
          def raw_html(content:)
            { type: "raw_html", content: content }
          end

          # Wrap an array of nodes in a versioned envelope for serialization.
          #
          # @param nodes [Array<Hash>] IR nodes
          # @return [Hash]
          def envelope(nodes)
            { version: VERSION, nodes: nodes }
          end
        end

        # Text truncation threshold (characters).
        TRUNCATE_LENGTH = 200

        # Renders an array of IR nodes to HTML.
        #
        # Produces HTML compatible with the existing metadata sidebar CSS classes
        # (.metadata-section, .metadata-label, .metadata-value, etc.) and uses
        # Alpine.js $store.expandable for expand/collapse of sections with children.
        #
        # Text values longer than TRUNCATE_LENGTH are truncated with a
        # "show more" / "show less" toggle via the data-ir-truncate attribute.
        class HtmlRenderer
          def initialize
            @expandable_counter = 0
          end

          # @param nodes [Array<Hash>] IR nodes
          # @return [String] HTML string
          def render(nodes)
            return "" if nodes.nil? || nodes.empty?

            nodes.map { |node| render_node(node) }.compact.join("\n")
          end

          private

          def next_expandable_id
            @expandable_counter += 1
            "ir_exp_#{@expandable_counter}"
          end

          def render_node(node)
            return nil unless node.is_a?(Hash) && node[:type]

            case node[:type].to_s
            when "section" then render_section(node)
            when "table"    then render_table(node)
            when "link"     then render_link(node)
            when "raw_html" then node[:content].to_s
            else nil # Unknown types silently skipped
            end
          end

          def render_section(node)
            label = h(node[:label])
            has_children = node[:children] && !node[:children].empty?
            parts = []

            if has_children
              exp_id = next_expandable_id

              # Clickable label header with toggle arrow
              badge_html = node[:badge] ? %( <span class="metadata-badge">#{h(node[:badge])}</span>) : ""
              parts << %(<div class="metadata-label ir-expandable-header" @click="$store.expandable.toggle('#{exp_id}')"><span class="expandable-toggle" x-text="$store.expandable.isExpanded('#{exp_id}') ? '▼' : '▶'">▶</span> #{label}#{badge_html}</div>)

              # Value (shown when collapsed, hidden when expanded)
              if node[:value] && !node[:language]
                parts << render_truncated_value(node[:value], %(x-show="!$store.expandable.isExpanded('#{exp_id}')"))
              end

              # Code block value (shown when expanded or always if no children toggle needed)
              if node[:value] && node[:language]
                parts << %(<pre class="metadata-code" x-show="$store.expandable.isExpanded('#{exp_id}')"><code class="language-#{h(node[:language])}">#{h(node[:value])}</code></pre>)
              end

              # Children (shown when expanded)
              children_html = node[:children].map { |child| render_node(child) }.compact.join("\n")
              parts << %(<div class="metadata-children" x-show="$store.expandable.isExpanded('#{exp_id}')" x-cloak>#{children_html}</div>)

              %(<div class="metadata-section expandable" data-ir-expandable="#{exp_id}">#{parts.join("\n")}</div>)
            else
              # Label with optional badge (non-expandable)
              badge_html = node[:badge] ? %( <span class="metadata-badge">#{h(node[:badge])}</span>) : ""
              parts << %(<div class="metadata-label">#{label}#{badge_html}</div>)

              # Value: code block or plain text
              if node[:value]
                if node[:language]
                  parts << %(<pre class="metadata-code"><code class="language-#{h(node[:language])}">#{h(node[:value])}</code></pre>)
                else
                  parts << render_truncated_value(node[:value])
                end
              end

              %(<div class="metadata-section">#{parts.join("\n")}</div>)
            end
          end

          def render_truncated_value(value, extra_attrs = nil)
            escaped = h(value)
            attrs = extra_attrs ? " #{extra_attrs}" : ""

            if value.length > TRUNCATE_LENGTH
              truncated_text = value[0, TRUNCATE_LENGTH]
              # For x-text: JS-escape first (for the JS string literal),
              # then HTML-escape (for the HTML attribute context).
              full_js = h(escape_js(value))
              truncated_js = h(escape_js(truncated_text))
              # Alpine.js component: x-data holds expanded state, x-text swaps content
              %(<div class="metadata-value ir-truncated" data-ir-truncate x-data="{ irExpanded: false }"#{attrs}><span x-text="irExpanded ? '#{full_js}' : '#{truncated_js}'">#{h(truncated_text)}</span><span class="ir-ellipsis" x-show="!irExpanded">...</span> <button type="button" class="ir-truncate-toggle" @click="irExpanded = !irExpanded" x-text="irExpanded ? 'show less' : 'show more'">show more</button></div>)
            else
              %(<div class="metadata-value"#{attrs}>#{escaped}</div>)
            end
          end

          def escape_js(text)
            text.to_s.gsub("\\", "\\\\").gsub("'", "\\\\'").gsub("\n", "\\n").gsub("\r", "\\r")
          end

          def render_table(node)
            headers = (node[:headers] || []).map { |h_text| "<th>#{h(h_text)}</th>" }.join
            rows = (node[:rows] || []).map do |row|
              cells = row.map { |cell| "<td>#{h(cell)}</td>" }.join
              "<tr>#{cells}</tr>"
            end.join("\n")

            %(<table class="metadata-table"><thead><tr>#{headers}</tr></thead><tbody>#{rows}</tbody></table>)
          end

          def render_link(node)
            %(<a href="#{h(node[:url])}" class="metadata-link" target="_blank" rel="noopener noreferrer">#{h(node[:text])}</a>)
          end

          def h(text)
            CGI.escapeHTML(text.to_s)
          end
        end

        # Wraps rendered HTML from a HAML template.
        #
        # When used inside a Builder block, the builder detects RenderResult
        # and automatically inserts a raw_html node. Outside build_ir, it
        # behaves like a String (delegates to_s, to_str).
        class RenderResult
          # @return [String] the rendered HTML
          attr_reader :html

          def initialize(html)
            @html = html.to_s
          end

          def to_s
            @html
          end

          def to_str
            @html
          end
        end

        # DSL builder for constructing IR node trees.
        #
        # Used via Extension#build_ir which creates a Builder instance and
        # evaluates a block in its context.
        #
        # When an optional extension is provided, unknown method calls (e.g.
        # render_template) are delegated to the extension. If the delegated
        # call returns a RenderResult, it is automatically inserted as a
        # raw_html node.
        #
        # @example
        #   builder = IR::Builder.new
        #   builder.instance_eval do
        #     section("Timestamp", value: "2026-02-13")
        #     section("Traces", badge: "2") do
        #       section("Trace 1", value: "...")
        #     end
        #   end
        #   builder.nodes  # => Array of IR node hashes
        class Builder
          # @return [Array<Hash>] the top-level collected nodes
          attr_reader :nodes

          # @param extension [Extension, nil] optional extension for method delegation
          def initialize(extension: nil)
            @nodes = []
            @stack = [@nodes]
            @extension = extension
          end

          # Add a section node.
          #
          # @param label [String] section heading
          # @param value [String, nil] inline text value
          # @param badge [String, nil] badge pill
          # @param language [String, nil] code block language
          # @yield optional block for nested children
          def section(label, value: nil, badge: nil, language: nil, &block)
            node = Nodes.section(label: label, value: value, badge: badge, language: language)
            if block
              node[:children] = []
              @stack.push(node[:children])
              instance_eval(&block)
              @stack.pop
            end
            @stack.last << node
            node
          end

          # Add a table node.
          #
          # @param headers [Array<String>] column headers
          # @param rows [Array<Array<String>>] row data
          def table(headers:, rows:)
            node = Nodes.table(headers: headers, rows: rows)
            @stack.last << node
            node
          end

          # Add a link node.
          #
          # @param text [String] link text
          # @param url [String] link URL
          def link(text, url:)
            node = Nodes.link(text: text, url: url)
            @stack.last << node
            node
          end

          # Add a raw_html node (escape hatch).
          # Rendered only in local/runner mode, dropped in hosted mode.
          #
          # @param content [String] raw HTML
          def raw_html(content)
            node = Nodes.raw_html(content: content)
            @stack.last << node
            node
          end

          # =====================================================================
          # Sugar methods
          # =====================================================================

          # Render a hash/array as a JSON code block.
          #
          # @param data [Hash, Array] data to pretty-print as JSON
          # @param label [String] section label (default: label must be provided by caller context)
          def json(label, data)
            section(label, value: JSON.pretty_generate(data), language: "json")
          end

          # Render a tool call as a section with Arguments/Result/Error subsections.
          #
          # @param name [String] tool call name
          # @param arguments [Hash, nil] tool call arguments
          # @param result [Object, nil] tool call result
          # @param error [String, nil] error message
          def tool_call(name, arguments: nil, result: nil, error: nil)
            section(name) do
              if arguments && (arguments.is_a?(Hash) ? !arguments.empty? : true)
                section("Arguments", value: JSON.pretty_generate(arguments), language: "json")
              end
              if result
                section("Result", value: JSON.pretty_generate(result), language: "json")
              end
              if error
                section("Error", value: error.to_s)
              end
            end
          end

          # Render a list of tool calls as a section with count badge.
          #
          # @param tool_calls_array [Array] tool calls (hashes or objects with name/arguments/result/error)
          def tool_calls_section(tool_calls_array)
            return if tool_calls_array.nil? || tool_calls_array.empty?

            section("Tool Calls", badge: tool_calls_array.size.to_s) do
              tool_calls_array.each do |tc|
                h = tc.is_a?(Hash) ? tc : { name: tc.name, arguments: tc.arguments, result: tc.result, error: tc.error }
                tool_call(
                  h[:name] || h["name"],
                  arguments: h[:arguments] || h["arguments"],
                  result: h[:result] || h["result"],
                  error: h[:error] || h["error"]
                )
              end
            end
          end

          # Render a timestamp as a section.
          #
          # @param time [Time, String] timestamp value
          def timestamp(time)
            section("Timestamp", value: time.respond_to?(:iso8601) ? time.iso8601 : time.to_s)
          end

          # Render key-value pairs from a hash as individual sections.
          #
          # @param hash [Hash] key-value pairs
          def kv(hash)
            hash.each { |k, v| section(k.to_s, value: v.to_s) }
          end

          # Render metrics as a JSON code block.
          #
          # @param hash [Hash] metrics data
          def metrics(hash)
            section("Metrics", value: JSON.pretty_generate(hash), language: "json")
          end

          private

          # Delegate unknown methods to the extension (e.g. render_template).
          # If the result is a RenderResult, auto-insert as raw_html node.
          def method_missing(method_name, *args, **kwargs, &block)
            if @extension&.respond_to?(method_name, true)
              result = @extension.send(method_name, *args, **kwargs, &block)
              if result.is_a?(RenderResult)
                raw_html(result.to_s)
              end
              result
            else
              super
            end
          end

          def respond_to_missing?(method_name, include_private = false)
            (@extension&.respond_to?(method_name, true)) || super
          end
        end
      end
    end
  end
end

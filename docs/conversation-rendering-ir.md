# Conversation Rendering: Intermediate Representation (IR)

**Status**: Implemented
**Date**: 2026-02-13

## Motivation

Extensions like `FrogChatExtension` render project-specific metadata using HAML
templates with arbitrary Ruby. In a hosted setup, we cannot execute that code.
We need an intermediate representation that:

1. Is **safe to render** on the hosted side (no arbitrary code execution)
2. Is **expressive enough** to cover the common rendering patterns
3. Is **produced by extensions** on the runner side (where Ruby is available)
4. Gracefully **degrades** — features that can't be expressed in the IR simply
   don't appear in hosted mode (the extension author can still use raw HTML/JS
   for local-only rendering)

## Design Principles

- **Data, not code**: The IR is a JSON-serializable data structure, not a template language
- **Component-oriented**: The IR describes *what* to render using a fixed vocabulary of node types, not *how* (no CSS classes, no JS handlers)
- **Minimal**: `section` is the single universal container. It handles labels, values, code blocks, badges, nesting, and expand/collapse. Text is always truncated by default.
- **No conditionals in IR**: The extension author handles all conditionals in Ruby before producing the IR. The IR is rendered as-is.
- **Forward-compatible**: Unknown node types are silently skipped. A `version` attribute in the serialization allows extensions to check capabilities.

## Node Types

The IR has **3 node types** plus one escape hatch.

### `section`

The universal container. Handles all structured content.

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `label` | string | Required. Section heading |
| `value` | string | Inline text value. Truncated at 200 chars by default |
| `badge` | string | Small pill shown after the label |
| `language` | string | When set, `value` is rendered as a syntax-highlighted code block |
| `children` | array | Nested nodes. When present, section is expandable/collapsible |

**Rendering rules:**

- Section with only `label` renders as a standalone label
- Section with `value` renders as label + inline value (key-value pair)
- Section with `language` renders `value` as a code block instead of plain text
- Section with `children` is expandable/collapsible
- Section with `value` + `children` shows value in collapsed state, children on expand
- Text values are truncated at 200 chars with "show more" control

**Examples:**

```json
{"type": "section", "label": "Timestamp", "value": "2026-02-13T10:30:45Z"}
```

```json
{"type": "section", "label": "LLM Traces", "badge": "3", "children": [...]}
```

```json
{
  "type": "section",
  "label": "Arguments",
  "language": "json",
  "value": "{\n  \"date_range\": \"2026-02-17..2026-02-21\"\n}"
}
```

```json
{
  "type": "section",
  "label": "System Prompt",
  "value": "You are a helpful assistant that manages hotel bookings...",
  "children": [
    {"type": "section", "label": "Full Prompt", "language": "text", "value": "You are a helpful assistant that manages hotel bookings and conference room reservations. You have access to the following tools..."}
  ]
}
```

### `table`

Tabular data.

```json
{
  "type": "table",
  "headers": ["Name", "Duration", "Status"],
  "rows": [
    ["search_documents", "42ms", "success"],
    ["get_weather", "128ms", "error"]
  ]
}
```

### `link`

A hyperlink.

```json
{
  "type": "link",
  "text": "View in Miceplace",
  "url": "https://example.com/supplier/123"
}
```

### `raw_html` (escape hatch)

Raw HTML content. **Rendered only in local/runner mode. Silently dropped in
hosted mode.**

```json
{
  "type": "raw_html",
  "content": "<button onclick=\"rerunTrace()\">Re-run</button>"
}
```

This is the mechanism for features that can't be expressed in the IR (interactive
modals, external API calls, custom JS behavior).

## What This Cannot Express (by design)

These features are excluded from hosted mode and only available via `raw_html`:

- Interactive modals (Mistral trace re-run)
- External API calls
- Custom JavaScript behavior (beyond expand/collapse)
- Custom CSS styling
- Interactive filtering (DB query filters)
- Copy to clipboard

## Extension API

### How Extensions Produce IR

Extensions use an IR builder DSL provided by the `Extension` base class.
The entry point is the `build_ir` method which creates a builder context.
The existing `render_template` helper returns a `RenderResult` that carries
HTML. When used inside a `build_ir` block, it automatically becomes a
`raw_html` node — rendered locally, dropped in hosted mode.

```ruby
class FrogChatExtension < Extension
  def render_message_metadata(message, message_id)
    traces = message.metadata&.dig(:traces) || []
    return nil if traces.empty?

    build_ir do
      section("LLM Traces", badge: traces.length.to_s) do
        traces.each_with_index do |trace, idx|
          section("Trace #{idx + 1}", badge: compute_duration(trace)) do
            if trace["system_prompt"]
              section("System Prompt", value: trace["system_prompt"])
            end

            if trace["tool_calls"]&.any?
              tool_calls_section(trace["tool_calls"])
            end

            if trace["output"]
              section("Output", value: trace.dig("output", "content"))
            end

            if trace["metrics"]&.any?
              section("Metrics", language: "json", value: JSON.pretty_generate(trace["metrics"]))
            end

            # Only rendered locally, dropped in hosted mode
            render_template("_rerun_button.html.haml", trace: trace)
          end
        end
      end
    end
  end
end
```

### Builder DSL

The builder methods are available inside `build_ir` blocks
and are provided by the `Extension` base class.

```ruby
# --- Core ---

# Sections (the universal container)
section("Label")                                  # standalone label
section("Label", value: "text")                   # key-value pair
section("Label", badge: "3") { ... }              # label + badge + children
section("Label", value: "code", language: "json") # code block
section("Label") { ... }                          # label + expandable children

# Tables
table(headers: [...], rows: [[...], ...])

# Links
link("View details", url: "https://...")

# Escape hatch (rendered locally only, dropped in hosted mode)
raw_html("<button>...</button>")

# --- Syntactic sugar ---

# JSON code block: shorthand for section with language: "json"
json("Label", data)
# expands to: section("Label", value: JSON.pretty_generate(data), language: "json")

# Tool call: expands to a section with Arguments/Result/Error subsections
tool_call("search_rooms",
  arguments: { date_range: "..." },
  result: { rooms: [...] },
  error: nil)

# Tool calls section: wraps multiple tool calls with a count badge
tool_calls_section(tool_calls_array)
# expands to: section("Tool Calls", badge: "N") { tool_call(...) for each }

# Timestamp: formats a Time/string value
timestamp(time_or_string)
# expands to: section("Timestamp", value: time.iso8601)

# Key-value list: renders multiple key-value pairs from a hash
# Useful for "Other Metadata" or any hash dump
kv(hash)
# expands to: section(key, value: val) for each key-value pair

# Metrics: renders a hash as labeled values
# metrics(data) expands to: section("Metrics", language: "json", value: ...)
metrics(hash)
```

### `render_template` Returns `RenderResult`

The `render_template` method returns a `RenderResult` object that carries HTML.
When used inside a `build_ir` block, the builder detects the `RenderResult` and
automatically inserts a `raw_html` node — rendered locally, dropped in hosted mode.

```ruby
# Inside a build_ir block, these are equivalent:
raw_html(render_template("_rerun_button.html.haml", trace: trace).to_s)
render_template("_rerun_button.html.haml", trace: trace)  # auto-inserted as raw_html

# Outside build_ir, render_template returns a RenderResult that behaves like a String:
html = render_template("_widget.html.haml", data: data)  # returns RenderResult
# RenderResult#to_s returns the HTML string

# An extension can return either:
# - IR nodes (from build_ir) → rendered in both local and hosted
# - String/RenderResult (from render_template) → rendered locally only
# - Mixed tree: inside build_ir, render_template calls become raw_html nodes
```

### Sugar Expansion Reference

| Sugar | Expands to |
|-------|------------|
| `json("Label", data)` | `section("Label", language: "json", value: JSON.pretty_generate(data))` |
| `tool_call(name, arguments:, result:, error:)` | `section(name) { section("Arguments", ...) section("Result", ...) ... }` |
| `tool_calls_section(array)` | `section("Tool Calls", badge: N) { tool_call(...) for each }` |
| `timestamp(time)` | `section("Timestamp", value: time.iso8601)` |
| `kv(hash)` | `section(key, value: val) for each pair` |
| `metrics(hash)` | `section("Metrics", language: "json", value: ...)` |

## Full Example: FrogChat Metadata as IR JSON

A message with one LLM trace containing a tool call:

```json
{
  "version": 1,
  "nodes": [
    {
      "type": "section",
      "label": "Timestamp",
      "value": "2026-02-13T10:30:45Z"
    },
    {
      "type": "section",
      "label": "LLM Traces",
      "badge": "1",
      "children": [
        {
          "type": "section",
          "label": "Trace 1",
          "badge": "42ms",
          "children": [
            {
              "type": "section",
              "label": "System Prompt",
              "value": "You are a helpful assistant that manages hotel bookings and conference room reservations..."
            },
            {
              "type": "section",
              "label": "Tool Calls",
              "badge": "1",
              "children": [
                {
                  "type": "section",
                  "label": "search_rooms",
                  "children": [
                    {
                      "type": "section",
                      "label": "Arguments",
                      "language": "json",
                      "value": "{\n  \"date_range\": \"2026-02-17..2026-02-21\",\n  \"type\": \"conference\"\n}"
                    },
                    {
                      "type": "section",
                      "label": "Result",
                      "language": "json",
                      "value": "{\n  \"rooms\": [{\"name\": \"Berlin\", \"capacity\": 20}]\n}"
                    }
                  ]
                }
              ]
            },
            {
              "type": "section",
              "label": "Output",
              "value": "Based on my search, the Berlin conference room is available next week with a capacity of 20 people."
            }
          ]
        }
      ]
    }
  ]
}
```

## Rendering

### Local Rendering (HTML)

When rendered locally (via `bin/rspec-agents` runner or agents-studio iframe),
IR nodes are converted to HTML by `IR::HtmlRenderer`. The HTML output uses
CSS classes from the existing metadata sidebar stylesheet and includes
client-side JavaScript for:

- **Text truncation**: Values longer than 200 characters are truncated with a
  "show more" / "show less" toggle
- **Expand/collapse**: Sections with children are collapsible, controlled via
  the Alpine.js expandable store

The `HtmlRenderer` emits `data-` attributes that the client-side JS picks up:

- `data-ir-truncate` on `.metadata-value` elements with long text
- `data-ir-expandable` with a unique ID on sections with children
- Alpine `x-show` / `@click` bindings for expand/collapse behavior

### Hosted Rendering

In hosted mode, the IR JSON is stored and served to the browser. The host
application renders IR nodes using its own component system. The host renderer:

- Renders `section` as collapsible containers (when children present)
- Renders `section` with `language` as syntax-highlighted code blocks
- Truncates text values at 200 chars with "show more"
- Renders `table` as a styled HTML table
- Renders `link` as a standard anchor tag
- Skips `raw_html` nodes entirely

Unknown node types are silently skipped (forward-compatible).

## Wire Format

When the runner pushes run data to the hosted studio, it includes the IR
alongside the raw conversation data:

```json
{
  "run_id": "run-2026-02-13T10-30-45Z-a1b2c3",
  "examples": {
    "example:abc123": {
      "description": "books a room successfully",
      "status": "passed",
      "conversation": { "turns": [...] },
      "rendered_extensions": {
        "message_metadata": {
          "msg_0": { "version": 1, "nodes": [...] },
          "msg_1": { "version": 1, "nodes": [...] }
        }
      }
    }
  }
}
```

# HTML Renderer Extension System

## Overview

The HTML rendering system consists of two renderer classes:

1. **`ConversationRenderer`** - Renders a single conversation (messages, tool calls, metadata)
2. **`TestSuiteRenderer`** - Renders test suite results (summary, example list) and uses `ConversationRenderer` for each example

Both renderers share a common extension system. Extensions implement hooks for both levels, with hook names disambiguating between them.

```
┌─────────────────────────────────────────────────────────┐
│                    TestSuiteRenderer                    │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Summary View  │  Example List  │  Aggregations   │  │
│  └───────────────────────────────────────────────────┘  │
│                           │                             │
│           ┌───────────────┼───────────────┐             │
│           ▼               ▼               ▼             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │ Conversation│  │ Conversation│  │ Conversation│      │
│  │  Renderer   │  │  Renderer   │  │  Renderer   │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
└─────────────────────────────────────────────────────────┘
```

## Extension Interface

### Base Class

All extensions inherit from `RSpec::Agents::Serialization::Extension`:

```ruby
module RSpec::Agents::Serialization
  class Extension
    attr_reader :renderer, :options

    def initialize(renderer, **options)
      @renderer = renderer
      @options = options
    end

    # Template directory for this extension (required for render_template)
    def template_dir
      raise NotImplementedError, "#{self.class} must implement template_dir"
    end

    # Ordering: lower priority = earlier in output
    def priority
      100
    end

    # =========================================================================
    # CONVERSATION-LEVEL HOOKS
    # Called by ConversationRenderer
    # =========================================================================

    # Document structure (when rendering standalone conversation)
    def conversation_head_content; end
    def conversation_body_start_content; end
    def conversation_body_end_content; end

    # Per-message hooks
    def render_before_message(message, message_id); end
    def render_message_attachment(message, message_id); end
    def render_after_message(message, message_id); end
    def render_message_metadata(message, message_id); end

    # =========================================================================
    # TEST SUITE-LEVEL HOOKS
    # Called by TestSuiteRenderer
    # =========================================================================

    # Document structure
    def suite_head_content; end
    def suite_body_start_content; end
    def suite_body_end_content; end

    # Summary view hooks
    def render_before_summary; end
    def render_after_summary; end
    def render_summary_header; end

    # Per-example hooks
    def render_before_example(example); end
    def render_after_example(example); end
    def render_example_header(example); end

    protected

    # Render a template from template_dir
    def render_template(name, **locals)
      path = File.join(template_dir, name)
      Tilt.new(path).render(self, **locals)
    end
  end
end
```

### Hook Points

#### Conversation Level

| Hook | Location | Use Case |
|------|----------|----------|
| `conversation_head_content` | Inside `<head>` | CSS, JS for conversation display |
| `conversation_body_start_content` | Start of conversation | Hidden containers, setup elements |
| `conversation_body_end_content` | End of conversation | Modals, toasts, floating UI |
| `render_before_message(message, message_id)` | Before message element | Status indicators, timestamps |
| `render_message_attachment(message, message_id)` | Inside message, before bubble | Tool calls, attachments |
| `render_after_message(message, message_id)` | After message element | Annotations, actions |
| `render_message_metadata(message, message_id)` | In metadata sidebar | Traces, debugging info |

#### Test Suite Level

| Hook | Location | Use Case |
|------|----------|----------|
| `suite_head_content` | Inside `<head>` | CSS, JS for suite display |
| `suite_body_start_content` | Start of body | Global UI elements |
| `suite_body_end_content` | End of body | Suite-level modals |
| `render_before_summary` | Before summary section | Custom headers |
| `render_after_summary` | After summary section | Additional statistics |
| `render_summary_header` | In summary header | Custom badges, links |
| `render_before_example(example)` | Before example container | Example badges |
| `render_after_example(example)` | After example container | Example footers |
| `render_example_header(example)` | In example header | Status indicators |

### Hook Execution Order

When multiple extensions implement the same hook:

1. Extensions are sorted by `priority` (ascending)
2. Each extension's hook is called in order
3. Non-nil return values are concatenated with newlines

## Renderer Classes

### ConversationRenderer

Renders a single conversation. Can be used standalone or embedded within `TestSuiteRenderer`.

```ruby
module RSpec::Agents::Serialization
  class ConversationRenderer
    attr_reader :conversation, :extensions

    def initialize(conversation, extensions: [])
      @conversation = conversation
      @extensions = instantiate_extensions(extensions)
    end

    # Render as full HTML document
    def render_document
      template = Tilt.new(document_template_path)
      template.render(self)
    end

    # Render as HTML fragment (for embedding)
    def render_fragment
      template = Tilt.new(fragment_template_path)
      template.render(self)
    end

    # Render to string
    def render_to_string(fragment: false)
      fragment ? render_fragment : render_document
    end

    # Extension hook aggregation
    def render_extensions(hook_name, *args)
      @extensions
        .map { |ext| ext.public_send(hook_name, *args) if ext.respond_to?(hook_name) }
        .compact
        .join("\n")
    end

    private

    def document_template_path
      # Full HTML document template
    end

    def fragment_template_path
      # Fragment template (no <html>/<head>/<body>)
    end
  end
end
```

### TestSuiteRenderer

Renders the test suite view with summary, example list, and embedded conversations.

```ruby
module RSpec::Agents::Serialization
  class TestSuiteRenderer
    attr_reader :run_data, :extensions, :output_path

    def initialize(run_data, output_path: nil, extensions: [])
      @run_data = run_data
      @output_path = output_path
      @extensions = instantiate_extensions(extensions)
    end

    # Render to file
    def render
      html_content = render_to_string
      File.write(output_path, html_content)
      output_path
    end

    # Render to string
    def render_to_string
      template = Tilt.new(template_path)
      template.render(self)
    end

    # Render a single example's conversation (delegates to ConversationRenderer)
    def render_conversation(example)
      ConversationRenderer.new(
        example.conversation,
        extensions: @extensions
      ).render_fragment
    end

    # Extension hook aggregation
    def render_extensions(hook_name, *args)
      @extensions
        .map { |ext| ext.public_send(hook_name, *args) if ext.respond_to?(hook_name) }
        .compact
        .join("\n")
    end
  end
end
```

## Template Structure

### Conversation Templates

**Document template** (`conversation.html.haml`):
```haml
!!!
%html
  %head
    %meta{charset: "UTF-8"}
    %title Conversation
    != render_base_styles
    != render_extensions(:conversation_head_content)

  %body
    != render_extensions(:conversation_body_start_content)
    != render_fragment
    != render_extensions(:conversation_body_end_content)
```

**Fragment template** (`_conversation_fragment.html.haml`):
```haml
.conversation
  - messages.each_with_index do |message, idx|
    - message_id = "msg_#{idx}"

    != render_extensions(:render_before_message, message, message_id)

    .message{class: message[:role], id: message_id}
      != render_extensions(:render_message_attachment, message, message_id)

      .message-bubble
        .message-content= message[:content]

    != render_extensions(:render_after_message, message, message_id)

.metadata-sidebar
  - messages.each_with_index do |message, idx|
    - message_id = "msg_#{idx}"
    .metadata-item{id: "#{message_id}_metadata"}
      != render_extensions(:render_message_metadata, message, message_id)
```

### Test Suite Template

**Main template** (`test_suite.html.haml`):
```haml
!!!
%html
  %head
    %meta{charset: "UTF-8"}
    %title RSpec Agents - Test Results
    != render_base_styles
    != render_extensions(:suite_head_content)
    != render_extensions(:conversation_head_content)

  %body
    != render_extensions(:suite_body_start_content)

    != render_extensions(:render_before_summary)
    #summary-view
      .summary-header
        != render_extensions(:render_summary_header)
        %h1 Test Summary
      -# ... summary content ...
    != render_extensions(:render_after_summary)

    #details-view
      - examples.each do |example|
        != render_extensions(:render_before_example, example)

        .example-content{id: example[:id]}
          .example-header
            != render_extensions(:render_example_header, example)
            %h2= example[:description]

          != render_conversation(example)

        != render_extensions(:render_after_example, example)

    != render_extensions(:conversation_body_end_content)
    != render_extensions(:suite_body_end_content)
```

Note: The test suite template calls both `suite_*` and `conversation_*` head/body hooks since it embeds conversations.

## Creating Extensions

### Extension for Conversation Only

```ruby
class ToolCallsExtension < RSpec::Agents::Serialization::Extension
  def template_dir
    File.expand_path("templates", __dir__)
  end

  def conversation_head_content
    "<style>#{read_asset('_tool_calls.css')}</style>"
  end

  def render_message_attachment(message, message_id)
    tool_calls = extract_tool_calls(message)
    return nil if tool_calls.empty?

    render_template("_tool_calls.html.haml",
      tool_calls: tool_calls,
      message_id: message_id
    )
  end
end
```

### Extension for Test Suite Only

```ruby
class SuiteStatsExtension < RSpec::Agents::Serialization::Extension
  def template_dir
    File.expand_path("templates", __dir__)
  end

  def suite_head_content
    "<style>#{read_asset('_stats.css')}</style>"
  end

  def render_summary_header
    render_template("_stats_badges.html.haml",
      run_data: renderer.run_data
    )
  end
end
```

### Extension for Both Levels

```ruby
class AnnotationsExtension < RSpec::Agents::Serialization::Extension
  def template_dir
    File.expand_path("templates", __dir__)
  end

  # Conversation-level: annotation triggers on messages
  def conversation_head_content
    "<style>#{read_asset('_annotations.css')}</style>"
  end

  def conversation_body_end_content
    render_template("_annotation_toast.html.haml")
  end

  def render_after_message(message, message_id)
    render_template("_annotation_trigger.html.haml",
      message: message,
      message_id: message_id
    )
  end

  # Suite-level: export all annotations
  def suite_body_end_content
    render_template("_export_button.html.haml")
  end
end
```

## Configuration

### For RSpec Test Runs

```ruby
RSpec::Agents.configure do |config|
  config.html_extensions = [
    FrogChat::TracesExtension,
    FrogChat::ToolCallsExtension,
  ]
end
```

The framework creates `TestSuiteRenderer` with `CoreExtension` always included as default, plus any extensions listed in `config.html_extensions` appended after it. Note: `AnnotationsExtension` is part of `agents-studio` and is not included by default in the base `rspec/agents` renderer.

### For Agents Studio (Conversation Only)

```ruby
module RSpec::AgentsStudio::Web::Services
  class ConversationService
    EXTENSIONS = [
      RSpec::AgentsStudio::Extensions::AnnotationsExtension,
      RSpec::AgentsStudio::Extensions::KeyboardNavigationExtension,
    ].freeze

    def render(conversation)
      RSpec::Agents::Serialization::ConversationRenderer.new(
        conversation,
        extensions: EXTENSIONS
      ).render_to_string
    end
  end
end
```

### For Custom Tools

```ruby
# Render just a conversation
conversation_html = ConversationRenderer.new(
  conversation,
  extensions: [MyExtension]
).render_to_string

# Render full test suite
suite_html = TestSuiteRenderer.new(
  run_data,
  extensions: [MyExtension]
).render_to_string
```

## Data Access

Both renderers expose `conversation` and `run_data` accessors. The value depends on context:

| Renderer | `conversation` | `run_data` |
|----------|----------------|------------|
| `ConversationRenderer` | The conversation being rendered | `nil` |
| `TestSuiteRenderer` | Current example's conversation (in message hooks) | The full run data |

```ruby
class MyExtension < Extension
  def render_message_metadata(message, message_id)
    # Always available
    conversation = renderer.conversation

    # Only available in TestSuiteRenderer context
    if renderer.run_data
      scenario = renderer.run_data.scenarios[example.scenario_id]
    end
  end
end
```

## Error Handling

Extensions should handle errors gracefully:

```ruby
def render_message_metadata(message, message_id)
  # ... rendering logic ...
rescue => e
  %(<div class="extension-error">Error in #{self.class}: #{e.message}</div>)
end
```

The renderer also wraps hook calls to prevent one failing extension from breaking the entire render.

---

# Appendix A: Migration from Current Template System

## Current Architecture

The existing system uses a single `HtmlRenderer` with configuration paths:

```ruby
RSpec::Agents.configure do |config|
  config.html_output_template = "path/to/conversation.html.haml"
  config.metadata_template = "path/to/_metadata.html.haml"
  config.head_template = "path/to/_head.html.haml"
  config.message_attachment_template = "path/to/_tool_calls.html.haml"
end
```

## Migration Steps

### Step 1: Create New Renderer Classes

Create `ConversationRenderer` and `TestSuiteRenderer` classes as described above.

### Step 2: Create Extension Directory Structure

```bash
mkdir -p lib/frog_chat/rspec_agents/extensions/templates
```

### Step 3: Create FrogChat Extension

```ruby
# lib/frog_chat/rspec_agents/extensions/frog_chat_extension.rb

module FrogChat::RSpecAgents
  class FrogChatExtension < RSpec::Agents::Serialization::Extension
    def template_dir
      File.expand_path("templates", __dir__)
    end

    def priority
      50
    end

    # Conversation-level hooks
    def conversation_head_content
      <<~HTML
        <style>#{read_asset("_styles.css")}</style>
        <script>#{read_asset("_scripts.js")}</script>
      HTML
    end

    def conversation_body_end_content
      render_template("_trace_rerun_modal.html.haml")
    end

    def render_message_attachment(message, message_id)
      tool_calls = extract_tool_calls(message)
      return nil if tool_calls.empty?

      render_template("_tool_calls.html.haml",
        message: message,
        message_id: message_id,
        tool_calls: tool_calls
      )
    end

    def render_message_metadata(message, message_id)
      render_template("_metadata.html.haml",
        message: message,
        message_id: message_id
      )
    end

    private

    def read_asset(name)
      File.read(File.join(template_dir, name))
    end

    def extract_tool_calls(message)
      metadata = message.metadata || {}
      (metadata['traces'] || metadata[:traces] || [])
        .flat_map { |t| t["tool_calls"] || [] }
    end
  end
end
```

### Step 4: Update Configuration

```ruby
# spec/agents_helper.rb

RSpec::Agents.configure do |config|
  config.html_extensions = [
    FrogChat::RSpecAgents::FrogChatExtension
  ]
end
```

### Step 5: Remove Old Configuration

Remove from `Configuration` class:
- `html_output_template`
- `metadata_template`
- `head_template`
- `message_attachment_template`

### Step 6: Delete Old HtmlRenderer

Replace `HtmlRenderer` with `TestSuiteRenderer` and `ConversationRenderer`.

## Hook Name Mapping

| Old Hook/Method | New Hook |
|-----------------|----------|
| `head_content` | `conversation_head_content` or `suite_head_content` |
| `body_start_content` | `conversation_body_start_content` or `suite_body_start_content` |
| `body_end_content` | `conversation_body_end_content` or `suite_body_end_content` |
| `render_before_example` | `render_before_example` (unchanged) |
| `render_after_example` | `render_after_example` (unchanged) |
| `render_before_message` | `render_before_message` (unchanged) |
| `render_message_attachment` | `render_message_attachment` (unchanged) |
| `render_after_message` | `render_after_message` (unchanged) |
| `render_metadata` | `render_message_metadata` |

---

# Appendix B: Agents Studio Setup

## Overview

Agents Studio uses `ConversationRenderer` directly to render conversations with studio-specific extensions.

## Directory Structure

```
lib/rspec/agents-studio/
  extensions/
    annotations_extension.rb
    annotations_templates/
      _annotations.css
      _annotations.js
  web/
    router.rb
```

## Annotations Extension

The `AnnotationsExtension` belongs exclusively to `agents-studio`. It is NOT included in the base `rspec/agents` renderer. Annotation UI elements (trigger buttons, toast, keyboard help, export button) are injected via the extension's CSS/JS and `conversation_body_end_content` hook. Annotation trigger buttons on messages and "Annotate Conversation" buttons on examples are dynamically injected via JavaScript at initialization time.

```ruby
# lib/rspec/agents-studio/extensions/annotations_extension.rb

module RSpec::AgentsStudio::Extensions
  class AnnotationsExtension < RSpec::Agents::Serialization::Extension
    def template_dir
      File.expand_path("annotations_templates", __dir__)
    end

    def conversation_head_content
      # Injects annotation CSS and JS
      styles = read_asset("_annotations.css")
      scripts = read_asset("_annotations.js")
      "<style>#{styles}</style>\n<script>#{scripts}</script>"
    end

    def conversation_body_end_content
      # Renders annotation toast, keyboard help, and export button
      # Annotation triggers on messages are injected dynamically by JS
    end

    private

    def read_asset(name)
      path = File.join(template_dir, name)
      File.exist?(path) ? File.read(path) : nil
    end
  end
end
```

## Conversation Service

```ruby
# lib/rspec/agents-studio/web/services/conversation_service.rb

module RSpec::AgentsStudio::Web::Services
  class ConversationService
    EXTENSIONS = [
      Extensions::AnnotationsExtension,
      Extensions::KeyboardNavigationExtension,
    ].freeze

    def render_to_string(conversation)
      RSpec::Agents::Serialization::ConversationRenderer.new(
        conversation,
        extensions: EXTENSIONS
      ).render_to_string
    end

    def render_fragment(conversation)
      RSpec::Agents::Serialization::ConversationRenderer.new(
        conversation,
        extensions: EXTENSIONS
      ).render_to_string(fragment: true)
    end
  end
end
```

## Verification Checklist

- [ ] `ConversationRenderer` renders standalone conversations correctly
- [ ] `TestSuiteRenderer` embeds conversations correctly
- [ ] Extensions with conversation-only hooks work in both contexts
- [ ] Extensions with suite-only hooks are ignored by `ConversationRenderer`
- [ ] Annotations work in agents-studio
- [ ] FrogChat traces work in test suite output

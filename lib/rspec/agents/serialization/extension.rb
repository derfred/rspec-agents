# frozen_string_literal: true

require "tilt"

module RSpec
  module Agents
    module Serialization
      # Base class for HTML renderer extensions.
      #
      # Extensions provide hooks for customizing HTML output at both the
      # conversation level (individual conversations) and suite level
      # (test suite reports).
      #
      # @example Creating a custom extension
      #   class MyExtension < RSpec::Agents::Serialization::Extension
      #     def template_dir
      #       File.expand_path("templates", __dir__)
      #     end
      #
      #     def conversation_head_content
      #       "<style>.my-class { color: red; }</style>"
      #     end
      #
      #     def render_after_message(message, message_id)
      #       render_template("_my_widget.html.haml", message: message)
      #     end
      #   end
      #
      class Extension
        attr_reader :renderer, :options

        # @param renderer [ConversationRenderer, TestSuiteRenderer] the renderer instance
        # @param options [Hash] extension-specific options
        def initialize(renderer, **options)
          @renderer = renderer
          @options = options
        end

        # Directory containing templates for this extension.
        # Required for render_template to work.
        #
        # @return [String] absolute path to templates directory
        def template_dir
          raise NotImplementedError, "#{self.class} must implement template_dir"
        end

        # Extension priority for ordering. Lower values run first.
        # Default is 100.
        #
        # @return [Integer]
        def priority
          100
        end

        # =========================================================================
        # CONVERSATION-LEVEL HOOKS
        # Called by ConversationRenderer
        # =========================================================================

        # Content to inject into <head> section for conversation rendering.
        # Typically CSS and JavaScript.
        #
        # @return [String, nil]
        def conversation_head_content; end

        # Content at the start of conversation body.
        # Useful for hidden containers or setup elements.
        #
        # @return [String, nil]
        def conversation_body_start_content; end

        # Content at the end of conversation body.
        # Useful for modals, toasts, or floating UI elements.
        #
        # @return [String, nil]
        def conversation_body_end_content; end

        # Content rendered before each message element.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [String, nil]
        def render_before_message(message, message_id); end

        # Content rendered inside the message, before the bubble.
        # Typically used for tool calls or attachments.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [String, nil]
        def render_message_attachment(message, message_id); end

        # Alpine x-bind:class expressions to merge into each message div.
        # Return a hash of class-name => Alpine-expression pairs.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [Hash, nil] e.g. { "selected" => "$store.foo.isSelected" }
        def render_message_classes(message, message_id); end

        # Content rendered inside .message-bubble-wrapper, after .message-bubble.
        # Used for action buttons, badges, or overlays that are siblings
        # of the message bubble.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [String, nil]
        def render_message_bubble_actions(message, message_id); end

        # Content rendered after each message element.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [String, nil]
        def render_after_message(message, message_id); end

        # Content rendered in the metadata sidebar for each message.
        #
        # @param message [MessagePresenter] the message being rendered
        # @param message_id [String] unique identifier for this message
        # @return [String, nil]
        def render_message_metadata(message, message_id); end

        # =========================================================================
        # TEST SUITE-LEVEL HOOKS
        # Called by TestSuiteRenderer
        # =========================================================================

        # Content to inject into <head> section for suite rendering.
        #
        # @return [String, nil]
        def suite_head_content; end

        # Content at the start of suite body.
        #
        # @return [String, nil]
        def suite_body_start_content; end

        # Content at the end of suite body.
        #
        # @return [String, nil]
        def suite_body_end_content; end

        # Content rendered before the summary section.
        #
        # @return [String, nil]
        def render_before_summary; end

        # Content rendered after the summary section.
        #
        # @return [String, nil]
        def render_after_summary; end

        # Content rendered in the summary header area.
        #
        # @return [String, nil]
        def render_summary_header; end

        # Content rendered before each example container.
        #
        # @param example [ExamplePresenter] the example being rendered
        # @return [String, nil]
        def render_before_example(example); end

        # Content rendered after each example container.
        #
        # @param example [ExamplePresenter] the example being rendered
        # @return [String, nil]
        def render_after_example(example); end

        # Content rendered in the example header area.
        #
        # @param example [ExamplePresenter] the example being rendered
        # @return [String, nil]
        def render_example_header(example); end

        protected

        # Render a template from this extension's template directory.
        #
        # @param name [String] template filename (e.g., "_widget.html.haml")
        # @param locals [Hash] local variables to pass to the template
        # @return [String] rendered HTML
        def render_template(name, **locals)
          path = File.join(template_dir, name)
          Tilt.new(path).render(self, **locals)
        end

        # Read an asset file from the template directory.
        #
        # @param name [String] asset filename (e.g., "_styles.css")
        # @return [String] file contents
        def read_asset(name)
          File.read(File.join(template_dir, name))
        end
      end
    end
  end
end

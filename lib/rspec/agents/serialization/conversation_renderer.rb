# frozen_string_literal: true

require "tilt"
require_relative "presenters"
require_relative "base_renderer"
require_relative "ir"

module RSpec
  module Agents
    module Serialization
      # Renders a single conversation as HTML.
      #
      # Can be used standalone to render a full HTML document, or as a fragment
      # for embedding within TestSuiteRenderer.
      #
      # Extension hooks can return either:
      # - A String (raw HTML) — rendered as-is (backward compatible)
      # - An Array of IR node hashes — rendered to HTML via IR::HtmlRenderer
      #
      # @example Standalone rendering
      #   renderer = ConversationRenderer.new(
      #     conversation,
      #     extensions: [MyExtension]
      #   )
      #   html = renderer.render_to_string
      #
      # @example Fragment for embedding
      #   renderer = ConversationRenderer.new(
      #     conversation,
      #     extensions: [MyExtension],
      #     example_id: "example_123"
      #   )
      #   fragment = renderer.render_to_string(fragment: true)
      #
      class ConversationRenderer < BaseRenderer
        attr_reader :conversation, :extensions, :run_data, :example_id

        # @param conversation [ConversationData] the conversation to render
        # @param extensions [Array<Class>] extension classes to use
        # @param run_data [RunData, nil] full run data (when rendering as part of suite)
        # @param example_id [String, nil] example identifier for message IDs
        def initialize(conversation, extensions: [], run_data: nil, example_id: nil)
          @conversation = conversation
          @run_data = run_data
          @example_id = example_id || "conv"
          @extensions = instantiate_extensions(extensions)
        end

        # Render as a full HTML document.
        #
        # @return [String] complete HTML document
        def render_document
          template = Tilt.new(document_template_path)
          template.render(self)
        end

        # Render as an HTML fragment (no <html>/<head>/<body>).
        #
        # @return [String] HTML fragment
        def render_fragment
          template = Tilt.new(fragment_template_path)
          template.render(self)
        end

        # Render to string.
        #
        # @param fragment [Boolean] if true, render as fragment; otherwise full document
        # @return [String] rendered HTML
        def render_to_string(fragment: false)
          fragment ? render_fragment : render_document
        end

        # Collect x-bind:class expressions from all extensions for a message.
        #
        # @param message [MessagePresenter] the message
        # @param message_id [String] unique identifier for this message
        # @return [Hash] merged class-name => Alpine-expression pairs
        def collect_message_classes(message, message_id)
          classes = {}
          @extensions.sort_by(&:priority).each do |ext|
            result = safe_call_hook(ext, :render_message_classes, message, message_id)
            classes.merge!(result) if result.is_a?(Hash)
          end
          classes
        end

        # Get messages from the conversation as presenters.
        #
        # @return [Array<MessagePresenter>]
        def messages
          @messages ||= flatten_conversation
        end

        # Build rendered_extensions IR data for JSON serialization.
        # Collects IR nodes from extension hooks for each message.
        #
        # @return [Hash] { message_metadata: { "msg_id" => { version: 1, nodes: [...] } } }
        def build_rendered_extensions
          message_metadata = {}

          messages.each_with_index do |message, idx|
            message_id = "#{example_id}_msg_#{idx}"
            nodes = collect_ir_nodes(:render_message_metadata, message, message_id)
            next if nodes.empty?

            message_metadata[message_id] = IR::Nodes.envelope(nodes)
          end

          { message_metadata: message_metadata }
        end

        private

        # Collect IR nodes from all extensions for a given hook.
        # Only extracts structured IR data (Array/Hash returns), ignoring Strings.
        #
        # @param hook_name [Symbol] the hook method name
        # @param args [Array] arguments to pass to the hook
        # @return [Array<Hash>] collected IR nodes
        def collect_ir_nodes(hook_name, *args)
          @extensions
            .sort_by(&:priority)
            .flat_map { |ext| extract_ir_from_hook(ext, hook_name, *args) }
            .compact
        end

        # Extract IR nodes from a single extension hook call.
        # Returns nil for String results (not IR).
        def extract_ir_from_hook(extension, hook_name, *args)
          return nil unless extension.respond_to?(hook_name)

          result = extension.public_send(hook_name, *args)
          case result
          when Array then result
          when Hash then [result]
          else nil
          end
        rescue StandardError
          nil
        end

        def flatten_conversation
          return [] unless @conversation

          @conversation.turns.flat_map do |turn|
            msgs = []
            msgs << MessagePresenter.new(turn.user_message) if turn.user_message
            msgs << MessagePresenter.new(turn.agent_response, tool_calls: turn.tool_calls) if turn.agent_response
            msgs
          end
        end

        def document_template_path
          File.expand_path("templates/conversation_document.html.haml", __dir__)
        end

        def fragment_template_path
          File.expand_path("templates/_conversation_fragment.html.haml", __dir__)
        end

      end
    end
  end
end

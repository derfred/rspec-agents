# frozen_string_literal: true

require_relative "ir"

module RSpec
  module Agents
    module Serialization
      # Common infrastructure shared by TestSuiteRenderer and ConversationRenderer.
      #
      # Provides:
      # - Extension instantiation and hook dispatch
      # - Hook result normalization (String, IR nodes, RenderResult)
      # - Base asset loading (CSS, JS, Alpine.js)
      #
      class BaseRenderer
        # Aggregate content from all extensions for a given hook.
        # Handles both String and IR node Array return values from hooks.
        #
        # @param hook_name [Symbol] the hook method name
        # @param args [Array] arguments to pass to the hook
        # @return [String] concatenated HTML output from all extensions
        def render_extensions(hook_name, *args)
          @extensions
            .sort_by(&:priority)
            .map { |ext| safe_call_hook(ext, hook_name, *args) }
            .compact
            .map { |result| normalize_hook_result(result) }
            .join("\n")
        end

        # Render base styles (CSS).
        #
        # @return [String] style tag with base CSS
        def render_base_styles
          content = read_base_asset("_base_components.css")
          return "" unless content

          "<style>#{content}</style>"
        end

        # Render base scripts (base components JS).
        #
        # @return [String] script tag with base JavaScript
        def render_base_scripts
          content = read_base_asset("_base_components.js")
          return "" unless content

          "<script>#{content}</script>"
        end

        # Render Alpine.js script. Must be called after all other scripts
        # so that alpine:init listeners are registered before Alpine starts.
        #
        # @return [String] script tag with Alpine.js
        def render_alpine_script
          alpine = read_base_asset("_alpine.min.js")
          return "" unless alpine

          "<script>#{alpine}</script>"
        end

        private

        def instantiate_extensions(extension_classes)
          extension_classes.map { |klass| klass.new(self) }
        end

        def safe_call_hook(extension, hook_name, *args)
          return nil unless extension.respond_to?(hook_name)

          extension.public_send(hook_name, *args)
        rescue StandardError => e
          %(<div class="extension-error">Error in #{extension.class}: #{e.message}</div>)
        end

        # Convert a hook result to HTML.
        # Handles String/RenderResult (pass-through), Array (IR nodes), and Hash (single IR node).
        def normalize_hook_result(result)
          case result
          when IR::RenderResult
            result.to_s
          when String
            result
          when Array
            IR::HtmlRenderer.new.render(result)
          when Hash
            IR::HtmlRenderer.new.render([result])
          else
            result.to_s
          end
        end

        def read_base_asset(name)
          path = File.expand_path("templates/#{name}", __dir__)
          File.exist?(path) ? File.read(path) : nil
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../extension"

module RSpec
  module Agents
    module Serialization
      module Extensions
        # Core extension providing base HTML rendering functionality.
        #
        # Includes:
        # - Base styles (`_styles.css`)
        # - Base scripts (`_scripts.js`)
        # - Metadata rendering via IR (timestamp, metadata, tool calls)
        #
        # This extension runs first (priority 0) to provide base functionality
        # that other extensions can build upon.
        #
        class CoreExtension < Extension
          def template_dir
            File.expand_path("../templates", __dir__)
          end

          def priority
            0  # Run first
          end

          # =========================================================================
          # CONVERSATION-LEVEL HOOKS
          # =========================================================================

          def conversation_head_content
            styles = read_asset("_styles.css")
            scripts = read_asset("_scripts.js")

            content = []
            content << "<style>#{styles}</style>" if styles
            content << "<script>#{scripts}</script>" if scripts
            content.join("\n")
          end

          # Render message metadata as IR nodes.
          # Returns an Array of IR node hashes (not HTML).
          #
          # @param message [MessagePresenter] the message
          # @param message_id [String] unique identifier
          # @return [Array<Hash>, nil] IR nodes or nil if nothing to render
          def render_message_metadata(message, message_id)
            build_ir do
              timestamp(message[:timestamp]) if message[:timestamp]

              if message[:metadata] && !message[:metadata].empty?
                section("Metadata", value: JSON.pretty_generate(message[:metadata]), language: "json")
              end

              if message[:tool_calls] && !message[:tool_calls].empty?
                tool_calls_section(message[:tool_calls])
              end
            end
          rescue StandardError => e
            %(<div class="metadata-error">Error rendering metadata: #{e.message}</div>)
          end

          # =========================================================================
          # SUITE-LEVEL HOOKS
          # =========================================================================

          # Suite template already calls conversation_head_content separately,
          # so we return nil here to avoid duplicating scripts.
          def suite_head_content; end

          private

          def read_asset(name)
            path = File.join(template_dir, name)
            File.exist?(path) ? File.read(path) : nil
          end
        end
      end
    end
  end
end

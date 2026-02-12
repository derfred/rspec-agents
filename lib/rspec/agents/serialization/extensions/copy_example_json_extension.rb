# frozen_string_literal: true

require_relative "../extension"

module RSpec
  module Agents
    module Serialization
      module Extensions
        # Copy Example JSON extension providing the ability to copy example JSON to clipboard.
        #
        # Includes:
        # - Copy JSON button in example headers
        # - JavaScript functionality to copy formatted JSON to clipboard
        #
        # This extension enables users to copy the full example data as JSON
        # for debugging or analysis purposes.
        #
        class CopyExampleJsonExtension < Extension
          def template_dir
            File.expand_path("copy_example_json_templates", __dir__)
          end

          def priority
            5  # Run after CoreExtension
          end

          # =========================================================================
          # CONVERSATION-LEVEL HOOKS
          # =========================================================================

          def conversation_head_content
            scripts = read_asset("_copy_example_json.js")

            content = []
            content << "<script>#{scripts}</script>" if scripts
            content.join("\n")
          end

          def suite_head_content
            conversation_head_content
          end

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

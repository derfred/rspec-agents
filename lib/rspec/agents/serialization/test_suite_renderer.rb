# frozen_string_literal: true

require "tilt"
require "fileutils"
require_relative "presenters"
require_relative "conversation_renderer"
require_relative "run_data_aggregator"
require_relative "extensions/core_extension"

module RSpec
  module Agents
    module Serialization
      # Renders test suite results as HTML with embedded conversations.
      #
      # @example Basic usage
      #   renderer = TestSuiteRenderer.new(run_data, output_path: "report.html")
      #   renderer.render
      #
      # @example With custom extensions
      #   renderer = TestSuiteRenderer.new(
      #     run_data,
      #     output_path: "report.html",
      #     extensions: [MyTracesExtension, MyToolCallsExtension]
      #   )
      #   renderer.render
      #
      class TestSuiteRenderer
        attr_reader :run_data, :extensions, :output_path

        # @param run_data [RunData] the test suite data to render
        # @param output_path [String, nil] output file path (optional)
        # @param extensions [Array<Class>, nil] extension classes (defaults to config)
        def initialize(run_data, output_path: nil, extensions: nil)
          @run_data = run_data
          @output_path = output_path
          @extensions = instantiate_extensions(extensions || config_extensions)
          @aggregator = RunDataAggregator.new(run_data)
        end

        # Convenience class method to render from RunData.
        #
        # @param run_data [RunData]
        # @param output_path [String, nil]
        # @param extensions [Array<Class>, nil]
        # @return [String, nil] output path if successful
        def self.render(run_data, output_path: nil, extensions: nil)
          new(run_data, output_path: output_path, extensions: extensions).render
        end

        # Convenience class method to render from JSON file.
        #
        # @param json_path [String] path to JSON file
        # @param output_path [String, nil]
        # @param extensions [Array<Class>, nil]
        # @return [String, nil] output path if successful
        def self.from_json_file(json_path, output_path: nil, extensions: nil)
          run_data = JsonFile.read(json_path)
          new(run_data, output_path: output_path, extensions: extensions).render
        end

        # Render to file.
        #
        # @return [String, nil] output path if successful
        def render
          html_content = render_to_string
          path = @output_path || default_output_path
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, html_content)
          path
        rescue StandardError => e
          warn "Failed to render HTML: #{e.message}"
          warn e.backtrace.first(5).join("\n")
          nil
        end

        # Render to string.
        #
        # @return [String] rendered HTML
        def render_to_string
          template = Tilt.new(template_path)
          template.render(self, examples: prepared_examples)
        end

        # Render a single example's conversation as a fragment.
        #
        # @param example [ExamplePresenter] the example to render
        # @return [String] HTML fragment
        def render_conversation(example)
          ConversationRenderer.new(
            example.conversation,
            extensions: @extensions.map(&:class),
            run_data:   @run_data,
            example_id: example[:id]
          ).render_fragment
        end

        # Aggregate content from all extensions for a given hook.
        #
        # @param hook_name [Symbol] the hook method name
        # @param args [Array] arguments to pass to the hook
        # @return [String] concatenated output from all extensions
        def render_extensions(hook_name, *args)
          @extensions
            .sort_by(&:priority)
            .map { |ext| safe_call_hook(ext, hook_name, *args) }
            .compact
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
        # Alpine.js is loaded last via render_alpine_script to ensure
        # all alpine:init listeners are registered before Alpine starts.
        #
        # @return [String] script tag with base JavaScript
        def render_base_scripts
          components = read_base_asset("_base_components.js")
          return "" unless components

          "<script>#{components}</script>"
        end

        # Render Alpine.js script. Must be called after all other scripts
        # so that alpine:init listeners are registered before Alpine starts.
        #
        # @return [String] script tag with Alpine.js
        def render_alpine_script
          alpine = read_base_asset("_alpine.min.js")
          unless alpine
            raise "Alpine.js not found. Run: bundle exec rake rspec_agents:download_alpine"
          end

          "<script>#{alpine}</script>"
        end

        # Get summary data for the summary view.
        #
        # @return [Hash]
        def summary_data
          @summary_data ||= @aggregator.summary_data(prepared_examples)
        end

        # Get aggregation data for the aggregation cards.
        #
        # @return [Hash]
        def aggregation_data
          @aggregation_data ||= @aggregator.aggregation_data
        end

        private

        def config_extensions
          default_extensions + RSpec::Agents.configuration.html_extensions
        end

        def default_extensions
          [
            Extensions::CoreExtension
          ]
        end

        def instantiate_extensions(extension_classes)
          extension_classes.map { |klass| klass.new(self) }
        end

        def safe_call_hook(extension, hook_name, *args)
          return nil unless extension.respond_to?(hook_name)

          extension.public_send(hook_name, *args)
        rescue StandardError => e
          %(<div class="extension-error">Error in #{extension.class}: #{e.message}</div>)
        end

        def prepared_examples
          @run_data.examples.values.map { |ex| ExamplePresenter.new(ex) }
        end

        def template_path
          File.expand_path("templates/test_suite.html.haml", __dir__)
        end

        def default_output_path
          if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
            Rails.root.join("tmp", "rspec_agents_debug.html").to_s
          else
            File.join(Dir.pwd, "tmp", "rspec_agents_debug.html")
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

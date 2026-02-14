# frozen_string_literal: true

require "tilt"
require "fileutils"
require_relative "presenters"
require_relative "conversation_renderer"
require_relative "base_renderer"
require_relative "ir"
require_relative "run_data_aggregator"
require_relative "extensions/core_extension"
require_relative "extensions/copy_example_json_extension"

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
      class TestSuiteRenderer < BaseRenderer
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

        # Render Alpine.js script. Raises if Alpine.js is missing since
        # the test suite report requires it for navigation and interactivity.
        #
        # @return [String] script tag with Alpine.js
        # @raise [RuntimeError] if Alpine.js asset is not found
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
            Extensions::CoreExtension,
            Extensions::CopyExampleJsonExtension
          ]
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

      end
    end
  end
end

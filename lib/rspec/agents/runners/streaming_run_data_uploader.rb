# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module RSpec
  module Agents
    module Runners
      # Uploads run data to an agents-studio webapp incrementally, one example at a time.
      # Each upload sends a minimal RunData containing run metadata + just that example.
      # The receiving /api/import endpoint is idempotent with respect to run_id, merging
      # examples into the same run record.
      #
      # Uses a background thread with a Queue so uploads never block spec execution.
      #
      # @example
      #   uploader = StreamingRunDataUploader.new(url: "http://localhost:9292", output: $stdout)
      #   uploader.start(run_data)
      #   executor.on_example_completed { |event, rd| uploader.upload_example(event, rd) }
      #   # ... after suite finishes ...
      #   uploader.finish
      #
      class StreamingRunDataUploader
        TIMEOUT = 10 # seconds per request

        # @param url [String] Base URL of the agents-studio webapp
        # @param output [IO] Output stream for status messages
        def initialize(url:, output: $stdout)
          @url = url.chomp("/")
          @output = output
          @queue = Queue.new
          @failed_examples = {}
          @mutex = Mutex.new
          @worker_thread = nil
          @http = nil
          @uploaded_count = 0
          @run_id = nil
        end

        # Whether the uploader has been started.
        def started?
          !!@run_id
        end

        # Start the background upload worker.
        # Idempotent — safe to call multiple times; only the first call takes effect.
        # @param run_data [Serialization::RunData] The run data (used for metadata)
        def start(run_data)
          return if started?

          @run_id = run_data.run_id
          @run_metadata = {
            run_id:     run_data.run_id,
            started_at: run_data.started_at,
            seed:       run_data.seed,
            git_commit: run_data.git_commit
          }
          @output.puts "Streaming run data to #{@url}..."
          @worker_thread = Thread.new { process_queue }
        end

        # Enqueue a single example for upload.
        # Meant to be called from an on_example_completed callback.
        # @param event [Events::ExamplePassed, Events::ExampleFailed, Events::ExamplePending]
        # @param run_data [Serialization::RunData] Current run data
        def upload_example(event, run_data)
          return unless @run_id

          example_data = run_data&.example(event.example_id)
          return unless example_data

          @queue.push([:upload, { example_id: event.example_id, example_data: example_data }])
        end

        # Signal the worker to finish: retry failed examples, then drain and stop.
        # Blocks until the worker thread completes (up to 60s).
        def finish
          return unless @worker_thread

          @queue.push([:finish, nil])
          @worker_thread.join(60)
          close_http

          if @uploaded_count > 0
            @output.puts "Upload complete: #{@uploaded_count} example#{"s" unless @uploaded_count == 1} streamed"
          end

          if @failed_examples.any?
            @output.puts "Warning: #{@failed_examples.size} example(s) failed to upload"
          end
        end

        private

        def process_queue
          loop do
            action, payload = @queue.pop

            case action
            when :upload
              do_upload_example(payload)
            when :finish
              retry_failed_examples
              break
            end
          end
        rescue => e
          @output.puts "Upload worker error: #{e.message}"
        end

        def do_upload_example(payload)
          example_data = payload[:example_data]
          stable_id = example_data.stable_id || payload[:example_id]

          # Build a minimal RunData with just this one example
          body = build_single_example_payload(example_data)
          post("/api/import", body)

          @mutex.synchronize do
            @uploaded_count += 1
            @failed_examples.delete(stable_id)
          end
        rescue => e
          @mutex.synchronize do
            @failed_examples[stable_id] = payload
          end
        end

        def retry_failed_examples
          failed = @mutex.synchronize { @failed_examples.dup }
          failed.each do |stable_id, payload|
            do_upload_example(payload)
          rescue
            # Leave in @failed_examples for final warning
          end
        end

        def build_single_example_payload(example_data)
          {
            run_id:     @run_metadata[:run_id],
            started_at: serialize_time(@run_metadata[:started_at]),
            seed:       @run_metadata[:seed],
            git_commit: @run_metadata[:git_commit],
            scenarios:  {},
            examples:   {
              example_data.id => example_data.to_h
            }
          }
        end

        def serialize_time(time)
          return nil unless time
          time.is_a?(Time) ? time.iso8601(3) : time
        end

        def http_connection
          @http ||= begin
            uri = URI.parse(@url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.open_timeout = TIMEOUT
            http.read_timeout = TIMEOUT
            http.start
            http
          end
        end

        def close_http
          @http&.finish
        rescue
          # Ignore close errors
        ensure
          @http = nil
        end

        def post(path, body)
          uri = URI.parse("#{@url}#{path}")
          request = Net::HTTP::Post.new(uri.path)
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)

          response = http_connection.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            raise "HTTP #{response.code}: #{response.body}"
          end
          response
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, IOError, Net::OpenTimeout, Net::ReadTimeout => e
          close_http # Reset connection on transport errors
          raise
        end
      end
    end
  end
end

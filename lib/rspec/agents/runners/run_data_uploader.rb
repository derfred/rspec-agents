# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module RSpec
  module Agents
    module Runners
      # Uploads run data to an agents-studio webapp via HTTP POST.
      # Used by TerminalRunner and ParallelTerminalRunner when --upload is specified.
      #
      # @example
      #   uploader = RunDataUploader.new(url: "http://localhost:9292")
      #   uploader.upload(run_data) # => true/false
      #
      class RunDataUploader
        TIMEOUT = 30 # seconds

        # @param url [String] Base URL of the agents-studio webapp
        # @param output [IO] Output stream for status messages
        def initialize(url:, output: $stdout)
          @url = url.chomp("/")
          @output = output
        end

        # Upload run data to the webapp.
        # @param run_data [Serialization::RunData] The run data to upload
        # @return [Boolean] true if upload succeeded
        def upload(run_data)
          return false unless run_data

          uri = URI.parse("#{@url}/api/import")
          json_body = JSON.generate(run_data.to_h)

          @output.puts "Uploading run data to #{@url}..."

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = TIMEOUT
          http.read_timeout = TIMEOUT

          request = Net::HTTP::Post.new(uri.path)
          request["Content-Type"] = "application/json"
          request.body = json_body

          response = http.request(request)

          if response.is_a?(Net::HTTPSuccess)
            result = JSON.parse(response.body)
            @output.puts "Upload complete: #{result["example_count"]} examples " \
                         "(#{result["passed_count"]} passed, #{result["failed_count"]} failed)"
            true
          else
            @output.puts "Upload failed (HTTP #{response.code}): #{response.body}"
            false
          end
        rescue Errno::ECONNREFUSED
          @output.puts "Upload failed: could not connect to #{@url} (is agents-studio running?)"
          false
        rescue Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout
          @output.puts "Upload failed: connection to #{@url} timed out"
          false
        rescue StandardError => e
          @output.puts "Upload failed: #{e.message}"
          false
        end
      end
    end
  end
end

# frozen_string_literal: true

require "spec_helper"
require "rspec/agents/runners/run_data_uploader"
require "rspec/agents/serialization"

RSpec.describe RSpec::Agents::Runners::RunDataUploader do
  let(:output) { StringIO.new }
  let(:url) { "http://localhost:9292" }

  subject(:uploader) { described_class.new(url: url, output: output) }

  let(:run_data) do
    RSpec::Agents::Serialization::RunData.new(
      run_id:     "run-123",
      started_at: Time.now,
      examples:   {
        "example-1" => RSpec::Agents::Serialization::ExampleData.new(
          id:          "example-1",
          stable_id:   "example:abc123",
          file:        "spec/test_spec.rb",
          description: "does something",
          location:    "spec/test_spec.rb:10",
          status:      :passed,
          started_at:  Time.now,
          finished_at: Time.now,
          duration_ms: 100
        )
      }
    )
  end

  def stub_request(status:, body:)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status == 200)
    response
  end

  def stub_http(response)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).with("localhost", 9292).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
    http
  end

  describe "#upload" do
    context "when upload succeeds" do
      it "returns true and prints success message" do
        response = stub_request(status: 200, body: {
          run_id: "run-123", example_count: 1, passed_count: 1, failed_count: 0
        })
        stub_http(response)

        result = uploader.upload(run_data)

        expect(result).to be true
        expect(output.string).to include("Uploading run data to http://localhost:9292...")
        expect(output.string).to include("Upload complete: 1 examples (1 passed, 0 failed)")
      end

      it "sends POST to /api/import with JSON body" do
        response = stub_request(status: 200, body: {
          run_id: "run-123", example_count: 1, passed_count: 1, failed_count: 0
        })
        http = stub_http(response)

        expect(http).to receive(:request) do |request|
          expect(request).to be_a(Net::HTTP::Post)
          expect(request.path).to eq("/api/import")
          expect(request["Content-Type"]).to eq("application/json")

          body = JSON.parse(request.body)
          expect(body["run_id"]).to eq("run-123")
          expect(body["examples"]).to have_key("example-1")

          response
        end

        uploader.upload(run_data)
      end
    end

    context "when run_data is nil" do
      it "returns false without making a request" do
        expect(Net::HTTP).not_to receive(:new)
        expect(uploader.upload(nil)).to be false
      end
    end

    context "when server returns an error" do
      it "returns false and prints error message for HTTP 400" do
        response = stub_request(status: 400, body: { error: "Invalid JSON" })
        stub_http(response)

        result = uploader.upload(run_data)

        expect(result).to be false
        expect(output.string).to include("Upload failed (HTTP 400)")
      end

      it "returns false and prints error message for HTTP 500" do
        response = stub_request(status: 500, body: { error: "Internal error" })
        stub_http(response)

        result = uploader.upload(run_data)

        expect(result).to be false
        expect(output.string).to include("Upload failed (HTTP 500)")
      end
    end

    context "when connection is refused" do
      it "returns false and prints friendly message" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

        result = uploader.upload(run_data)

        expect(result).to be false
        expect(output.string).to include("could not connect to http://localhost:9292")
        expect(output.string).to include("is agents-studio running?")
      end
    end

    context "when connection times out" do
      it "returns false for open timeout" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Net::OpenTimeout)

        result = uploader.upload(run_data)

        expect(result).to be false
        expect(output.string).to include("timed out")
      end

      it "returns false for read timeout" do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_raise(Net::ReadTimeout)

        result = uploader.upload(run_data)

        expect(result).to be false
        expect(output.string).to include("timed out")
      end
    end

    context "with custom URL" do
      let(:url) { "http://myhost:4000" }

      it "connects to the custom host and port" do
        response = stub_request(status: 200, body: {
          run_id: "run-123", example_count: 1, passed_count: 1, failed_count: 0
        })

        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).with("myhost", 4000).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(response)

        result = uploader.upload(run_data)

        expect(result).to be true
        expect(output.string).to include("Uploading run data to http://myhost:4000...")
      end
    end

    context "with trailing slash in URL" do
      let(:url) { "http://localhost:9292/" }

      it "strips the trailing slash in output" do
        response = stub_request(status: 200, body: {
          run_id: "run-123", example_count: 1, passed_count: 1, failed_count: 0
        })
        stub_http(response)

        uploader.upload(run_data)
        expect(output.string).to include("Uploading run data to http://localhost:9292...")
        expect(output.string).not_to include("http://localhost:9292/...")
      end
    end
  end
end

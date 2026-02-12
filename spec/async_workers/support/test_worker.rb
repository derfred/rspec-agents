#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple worker script for AsyncWorkers integration tests
# Implements the JSON-RPC protocol over stdio

$stdout.sync = true
$stderr.sync = true

require "json"

def send_response(output, request_id, payload)
  response = payload.merge(reply_to: request_id)
  output.puts(response.to_json)
  output.flush
end

def send_notification(output, payload)
  output.puts(payload.to_json)
  output.flush
end

running = true

while running && (line = $stdin.gets)
  begin
    msg = JSON.parse(line.chomp, symbolize_names: true)

    case msg[:action]
    when "__shutdown__"
      running = false
      send_response($stdout, msg[:id], { status: "shutting_down" })

    when "echo"
      send_response($stdout, msg[:id], { result: msg[:data] })

    when "add"
      result = msg[:a].to_i + msg[:b].to_i
      send_response($stdout, msg[:id], { result: result })

    when "sleep"
      sleep(msg[:seconds] || 1)
      send_response($stdout, msg[:id], { result: "done" })

    when "crash"
      exit(msg[:code] || 1)

    when "hang"
      sleep(3600)

    when "log"
      $stderr.puts("[worker] #{msg[:message]}")
      send_response($stdout, msg[:id], { result: "logged" })

    when "notify_progress"
      count = msg[:count] || 5
      count.times do |i|
        send_notification($stdout, { type: "progress", percent: ((i + 1) * 100.0 / count).round })
        sleep(0.1)
      end
      send_response($stdout, msg[:id], { result: "complete" })

    when "env"
      send_response($stdout, msg[:id], {
        result: {
          worker_index:  ENV["WORKER_INDEX"],
          rpc_socket_fd: ENV["RPC_SOCKET_FD"]
        }
      })

    # M4: slow - timed response
    when "slow"
      sleep(msg[:seconds] || 1)
      send_response($stdout, msg[:id], { result: "slow_done" })

    # M4: error - explicit error response
    when "error"
      send_response($stdout, msg[:id], {
        error: { code: msg[:code] || -1, message: msg[:message] || "error" }
      })

    # M5: start_heartbeat - autonomous periodic notifications
    when "start_heartbeat"
      count = msg[:count] || 10
      interval = msg[:interval] || 0.5
      Thread.new do
        count.times do |i|
          send_notification($stdout, { type: "heartbeat", seq: i })
          sleep(interval)
        end
      end
      send_response($stdout, msg[:id], { result: "heartbeat_started" })

    # M6: log_message - logs the received message structure to stderr
    when "log_message"
      has_id = msg.key?(:id)
      $stderr.puts("[message] type=#{has_id ? "request" : "notification"} action=#{msg[:action]}")
      send_response($stdout, msg[:id], { result: "logged" }) if has_id

    # M8: malformed - send malformed JSON
    when "malformed"
      $stdout.puts("{ this is not valid json")
      $stdout.flush
      send_response($stdout, msg[:id], { result: "malformed_sent" })

    # M8: close_early - close stdout abruptly
    when "close_early"
      $stdout.close
    # No response possible

    # M10: conditional_fail - fail if WORKER_INDEX matches
    when "conditional_fail"
      fail_index = (ENV["FAIL_INDEX"] || msg[:fail_index])&.to_s
      if ENV["WORKER_INDEX"] == fail_index
        sleep(msg[:delay] || 0.5)
        exit(msg[:code] || 1)
      else
        send_response($stdout, msg[:id], { result: "not_failing" })
      end

    # M12: compute - double input (design example)
    when "compute"
      result = (msg[:x] || 0) * 2
      send_response($stdout, msg[:id], { result: result })

    # M13: long_task - with progress and log notifications
    when "long_task"
      steps = msg[:steps] || 5
      steps.times do |i|
        send_notification($stdout, { type: "progress", step: i + 1, total: steps })
        send_notification($stdout, { type: "log", message: "Processing step #{i + 1}" })
        sleep(0.1)
      end
      send_response($stdout, msg[:id], { result: "complete" })

    # M14: process_file - simulate file processing
    when "process_file"
      filename = msg[:filename] || "unknown"
      sleep(msg[:duration] || 0.1)
      send_response($stdout, msg[:id], {
        result: {
          filename:     filename,
          worker_index: ENV["WORKER_INDEX"],
          status:       "processed"
        }
      })

    else
      send_response($stdout, msg[:id], { error: "unknown action: #{msg[:action]}" })
    end
  rescue JSON::ParserError => e
    $stderr.puts("[worker] JSON parse error: #{e.message}")
  rescue => e
    $stderr.puts("[worker] Error: #{e.class}: #{e.message}")
  end
end

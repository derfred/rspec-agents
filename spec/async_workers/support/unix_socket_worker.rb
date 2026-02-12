#!/usr/bin/env ruby
# frozen_string_literal: true

# Unix socket RPC worker for testing unix_socket_rpc mode
# Reads RPC_SOCKET_FD from environment and uses it for JSON-RPC

$stdout.sync = true
$stderr.sync = true

require "json"

fd_str = ENV["RPC_SOCKET_FD"]
unless fd_str
  $stderr.puts("ERROR: RPC_SOCKET_FD not set")
  exit(1)
end

fd = fd_str.to_i
socket = IO.for_fd(fd, mode: "r+")
socket.sync = true

def send_response(socket, request_id, payload)
  response = payload.merge(reply_to: request_id)
  socket.puts(response.to_json)
  socket.flush
end

def send_notification(socket, payload)
  socket.puts(payload.to_json)
  socket.flush
end

$stdout.puts("unix_socket_worker started with fd=#{fd}")
$stderr.puts("worker ready")

running = true

while running && (line = socket.gets)
  begin
    msg = JSON.parse(line.chomp, symbolize_names: true)

    case msg[:action]
    when "__shutdown__"
      running = false
      send_response(socket, msg[:id], { status: "shutting_down" })

    when "echo"
      $stdout.puts("echoing: #{msg[:data]}")
      send_response(socket, msg[:id], { result: msg[:data] })

    when "add"
      result = msg[:a].to_i + msg[:b].to_i
      send_response(socket, msg[:id], { result: result })

    when "env"
      send_response(socket, msg[:id], {
        result: {
          worker_index:  ENV["WORKER_INDEX"],
          rpc_socket_fd: ENV["RPC_SOCKET_FD"]
        }
      })

    when "log_to_stdout"
      $stdout.puts("stdout: #{msg[:message]}")
      send_response(socket, msg[:id], { result: "logged_to_stdout" })

    when "log_to_stderr"
      $stderr.puts("stderr: #{msg[:message]}")
      send_response(socket, msg[:id], { result: "logged_to_stderr" })

    when "compute"
      result = (msg[:x] || 0) * 2
      send_response(socket, msg[:id], { result: result })

    when "notify_progress"
      count = msg[:count] || 5
      count.times do |i|
        send_notification(socket, { type: "progress", percent: ((i + 1) * 100.0 / count).round })
        sleep(0.1)
      end
      send_response(socket, msg[:id], { result: "complete" })

    else
      send_response(socket, msg[:id], { error: "unknown action: #{msg[:action]}" })
    end
  rescue JSON::ParserError => e
    $stderr.puts("[worker] JSON parse error: #{e.message}")
  rescue => e
    $stderr.puts("[worker] Error: #{e.class}: #{e.message}")
  end
end

$stderr.puts("worker exiting")

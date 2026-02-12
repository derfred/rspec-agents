#!/usr/bin/env ruby
# frozen_string_literal: true

# Output-only worker for testing no_rpc mode
# Supports multiple modes via command-line argument:
#   ruby output_worker.rb sleep <seconds>   - M1: Exit after sleep
#   ruby output_worker.rb sigterm            - M2: SIGTERM handler (graceful)
#   ruby output_worker.rb sigterm_ignore     - M2: SIGTERM ignore mode
#   ruby output_worker.rb lines <count>      - M3: Output numbered lines
#   ruby output_worker.rb crash <code>       - M8: Crash with exit code

$stdout.sync = true
$stderr.sync = true

mode = ARGV[0] || "sleep"
arg = ARGV[1]

case mode
when "sleep"
  # M1: Simple exit-after-sleep
  duration = (arg || 1).to_f
  $stderr.puts("pid=#{Process.pid}")
  sleep(duration)
  exit(0)

when "sigterm"
  # M2: SIGTERM handler - graceful
  trap("TERM") do
    $stderr.puts("SIGTERM received")
    exit(0)
  end
  trap("USR1") do
    $stderr.puts("USR1 received")
  end
  $stderr.puts("pid=#{Process.pid}")
  loop { sleep(1) }

when "sigterm_ignore"
  # M2: SIGTERM ignore - requires SIGKILL
  trap("TERM") do
    $stderr.puts("SIGTERM ignored")
  end
  $stderr.puts("pid=#{Process.pid}")
  loop { sleep(0.1) }

when "lines"
  # M3: Numbered line output to both stdout and stderr
  count = (arg || 5).to_i
  delay = (ARGV[2] || 0.1).to_f
  count.times do |i|
    $stdout.puts("stdout line #{i + 1}")
    $stderr.puts("stderr line #{i + 1}")
    sleep(delay)
  end
  exit(0)

when "crash"
  # M8: Crash after optional delay
  code = (arg || 42).to_i
  delay = (ARGV[2] || 0).to_f
  sleep(delay) if delay > 0
  exit(code)

else
  $stderr.puts("Unknown mode: #{mode}")
  exit(1)
end

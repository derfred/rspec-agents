# frozen_string_literal: true

require "async"

require_relative "async_workers/errors"
require_relative "async_workers/channel_config"
require_relative "async_workers/output_stream"
require_relative "async_workers/transport/base"
require_relative "async_workers/transport/stdio_transport"
require_relative "async_workers/transport/unix_socket_transport"
require_relative "async_workers/rpc_channel"
require_relative "async_workers/managed_process"
require_relative "async_workers/worker_group"

module AsyncWorkers
  VERSION = "0.1.0"
end

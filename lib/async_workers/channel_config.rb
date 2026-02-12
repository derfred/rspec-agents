# frozen_string_literal: true

module AsyncWorkers
  # Configuration for RPC channel mode
  # Immutable value object using Data.define
  ChannelConfig = Data.define(:mode, :options) do
    # RPC over stdin/stdout, logs on stderr only
    def self.stdio_rpc
      new(mode: :stdio_rpc, options: {})
    end

    # RPC over unix domain socket, logs on stdout/stderr
    def self.unix_socket_rpc
      new(mode: :unix_socket_rpc, options: {})
    end

    # No RPC, just output capture
    def self.no_rpc
      new(mode: :no_rpc, options: {})
    end

    def rpc_enabled?
      mode != :no_rpc
    end

    def stdio?
      mode == :stdio_rpc
    end

    def unix_socket?
      mode == :unix_socket_rpc
    end
  end
end

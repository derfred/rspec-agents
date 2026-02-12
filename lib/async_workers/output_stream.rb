# frozen_string_literal: true

module AsyncWorkers
  # Unified callback and iterator interface for streaming data.
  # Thread-safe, supports multiple callbacks and blocking iteration.
  #
  # @example Callback style
  #   stream.on_data { |item| puts item }
  #
  # @example Iterator style (blocking, use in dedicated task)
  #   stream.each { |item| puts item }
  #
  # @example Enumerable
  #   stream.each.take(10)
  #
  class OutputStream
    include Enumerable

    def initialize
      @callbacks = []
      @mutex     = Mutex.new
      @queue     = Thread::Queue.new
      @closed    = false
    end

    # Register callback for incoming data.
    # Multiple callbacks can be registered and will all be called.
    #
    # @yield [item] Block called for each item
    # @return [self]
    def on_data(&block)
      @mutex.synchronize { @callbacks << block }
      self
    end

    # Blocking iterator - yields until stream closes.
    # Use in a dedicated async task to avoid blocking other operations.
    #
    # @yield [item] Block called for each item
    # @return [Enumerator] if no block given
    def each
      return enum_for(:each) unless block_given?

      loop do
        item = @queue.pop
        break if item.equal?(CLOSED_SENTINEL)
        yield item
      end
    end

    # Check if stream is closed
    # @return [Boolean]
    def closed?
      @closed
    end

    # @api private
    # Emit item to all callbacks and the iterator queue
    def emit(item)
      return if @closed

      callbacks = @mutex.synchronize { @callbacks.dup }
      callbacks.each do |cb|
        cb.call(item)
      rescue => e
        warn "[AsyncWorkers::OutputStream] Callback error: #{e.class}: #{e.message}"
      end

      @queue.push(item)
    end

    # @api private
    # Close the stream, signaling iterators to stop
    def close
      return if @closed
      @closed = true
      @queue.push(CLOSED_SENTINEL)
    end

    private

    # Sentinel object to signal stream closure
    CLOSED_SENTINEL = Object.new.freeze
    private_constant :CLOSED_SENTINEL
  end
end

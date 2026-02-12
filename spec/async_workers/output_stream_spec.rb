# frozen_string_literal: true

require "async"
require_relative "../../lib/async_workers"

RSpec.describe AsyncWorkers::OutputStream do
  let(:stream) { described_class.new }

  describe "#on_data" do
    it "registers a callback" do
      received = []
      stream.on_data { |item| received << item }

      stream.emit("hello")
      stream.emit("world")

      expect(received).to eq(["hello", "world"])
    end

    it "supports multiple callbacks" do
      received_a = []
      received_b = []

      stream.on_data { |item| received_a << item }
      stream.on_data { |item| received_b << item }

      stream.emit("test")

      expect(received_a).to eq(["test"])
      expect(received_b).to eq(["test"])
    end

    it "returns self for chaining" do
      result = stream.on_data { |_| }
      expect(result).to be(stream)
    end

    it "handles callback exceptions gracefully" do
      received = []
      stream.on_data { |_| raise "boom" }
      stream.on_data { |item| received << item }

      expect { stream.emit("test") }.not_to raise_error
      expect(received).to eq(["test"])
    end
  end

  describe "#each" do
    it "yields items as they are emitted" do
      received = []

      Async do |task|
        # Consumer task
        consumer = task.async do
          stream.each { |item| received << item }
        end

        # Producer
        stream.emit("a")
        stream.emit("b")
        stream.emit("c")
        stream.close

        consumer.wait
      end

      expect(received).to eq(["a", "b", "c"])
    end

    it "returns an enumerator when no block given" do
      enumerator = stream.each
      expect(enumerator).to be_a(Enumerator)
    end

    it "supports take with enumerator" do
      Async do |task|
        task.async do
          5.times { |i| stream.emit("item #{i}") }
          stream.close
        end

        result = stream.each.take(3)
        expect(result).to eq(["item 0", "item 1", "item 2"])
      end
    end

    it "stops iteration when stream closes" do
      iterations = 0

      Async do |task|
        consumer = task.async do
          stream.each { iterations += 1 }
        end

        stream.emit("one")
        stream.emit("two")
        stream.close

        consumer.wait
      end

      expect(iterations).to eq(2)
    end
  end

  describe "#closed?" do
    it "returns false initially" do
      expect(stream.closed?).to be false
    end

    it "returns true after close" do
      stream.close
      expect(stream.closed?).to be true
    end
  end

  describe "#emit" do
    it "does not emit after close" do
      received = []
      stream.on_data { |item| received << item }

      stream.emit("before")
      stream.close
      stream.emit("after")

      expect(received).to eq(["before"])
    end
  end

  describe "#close" do
    it "is idempotent" do
      expect { 3.times { stream.close } }.not_to raise_error
      expect(stream.closed?).to be true
    end
  end

  describe "combined callback and iterator usage" do
    it "both receive all items" do
      callback_items = []
      iterator_items = []

      Async do |task|
        stream.on_data { |item| callback_items << item }

        consumer = task.async do
          stream.each { |item| iterator_items << item }
        end

        stream.emit("x")
        stream.emit("y")
        stream.close

        consumer.wait
      end

      expect(callback_items).to eq(["x", "y"])
      expect(iterator_items).to eq(["x", "y"])
    end
  end

  describe "Enumerable" do
    it "includes Enumerable" do
      expect(described_class.ancestors).to include(Enumerable)
    end

    it "supports select" do
      Async do |task|
        task.async do
          (1..5).each { |i| stream.emit(i) }
          stream.close
        end

        result = stream.each.select { |i| i.even? }
        expect(result).to eq([2, 4])
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../../lib/async_workers"

RSpec.describe AsyncWorkers::ChannelConfig do
  describe ".stdio_rpc" do
    subject { described_class.stdio_rpc }

    it "creates a config with :stdio_rpc mode" do
      expect(subject.mode).to eq(:stdio_rpc)
    end

    it "has empty options" do
      expect(subject.options).to eq({})
    end

    it "reports rpc_enabled? as true" do
      expect(subject.rpc_enabled?).to be true
    end

    it "reports stdio? as true" do
      expect(subject.stdio?).to be true
    end

    it "reports unix_socket? as false" do
      expect(subject.unix_socket?).to be false
    end
  end

  describe ".unix_socket_rpc" do
    subject { described_class.unix_socket_rpc }

    it "creates a config with :unix_socket_rpc mode" do
      expect(subject.mode).to eq(:unix_socket_rpc)
    end

    it "has empty options" do
      expect(subject.options).to eq({})
    end

    it "reports rpc_enabled? as true" do
      expect(subject.rpc_enabled?).to be true
    end

    it "reports stdio? as false" do
      expect(subject.stdio?).to be false
    end

    it "reports unix_socket? as true" do
      expect(subject.unix_socket?).to be true
    end
  end

  describe ".no_rpc" do
    subject { described_class.no_rpc }

    it "creates a config with :no_rpc mode" do
      expect(subject.mode).to eq(:no_rpc)
    end

    it "has empty options" do
      expect(subject.options).to eq({})
    end

    it "reports rpc_enabled? as false" do
      expect(subject.rpc_enabled?).to be false
    end

    it "reports stdio? as false" do
      expect(subject.stdio?).to be false
    end

    it "reports unix_socket? as false" do
      expect(subject.unix_socket?).to be false
    end
  end

  describe "immutability" do
    it "is frozen by default (Data.define behavior)" do
      config = described_class.stdio_rpc
      expect(config).to be_frozen
    end
  end
end

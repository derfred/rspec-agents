require "spec_helper"
require "rspec/agents"

RSpec.describe RSpec::Agents::TopicGraph do
  def build_topic(name, &block)
    RSpec::Agents::Topic.new(name, &block)
  end

  describe "#initialize" do
    it "starts with empty topics" do
      graph = described_class.new
      expect(graph.empty?).to be true
    end

    it "has no initial topic" do
      graph = described_class.new
      expect(graph.initial_topic).to be_nil
    end
  end

  describe "#add_topic" do
    it "adds topic to graph" do
      graph = described_class.new
      topic = build_topic(:greeting)

      graph.add_topic(topic)

      expect(graph[:greeting]).to eq(topic)
    end

    it "sets first topic as initial" do
      graph = described_class.new
      graph.add_topic(build_topic(:greeting))
      graph.add_topic(build_topic(:gathering))

      expect(graph.initial_topic).to eq(:greeting)
    end

    it "accepts next_topics parameter" do
      graph = described_class.new
      graph.add_topic(build_topic(:greeting), next_topics: :gathering)
      graph.add_topic(build_topic(:gathering))

      expect(graph.successors_of(:greeting)).to eq([:gathering])
    end

    it "accepts array of next_topics" do
      graph = described_class.new
      graph.add_topic(build_topic(:greeting), next_topics: [:a, :b])
      graph.add_topic(build_topic(:a))
      graph.add_topic(build_topic(:b))

      expect(graph.successors_of(:greeting)).to eq([:a, :b])
    end

    it "raises on duplicate topic" do
      graph = described_class.new
      graph.add_topic(build_topic(:greeting))

      expect {
        graph.add_topic(build_topic(:greeting))
      }.to raise_error(RSpec::Agents::DuplicateTopicError, /greeting.*already defined/)
    end
  end

  describe "#use_topic" do
    it "wires shared topic into graph" do
      shared_topics = {
        greeting: build_topic(:greeting) do
          characteristic "Initial contact"
        end
      }

      graph = described_class.new
      graph.use_topic(:greeting, next_topics: :gathering, shared_topics: shared_topics)
      graph.add_topic(build_topic(:gathering))
      graph.validate!

      expect(graph[:greeting].characteristic_text).to eq("Initial contact")
      expect(graph.successors_of(:greeting)).to eq([:gathering])
    end

    it "allows updating edges for existing topic" do
      graph = described_class.new
      graph.add_topic(build_topic(:greeting), next_topics: :a)
      graph.add_topic(build_topic(:a))
      graph.add_topic(build_topic(:b))

      # Update edges
      graph.use_topic(:greeting, next_topics: [:a, :b])
      graph.validate!

      expect(graph.successors_of(:greeting)).to eq([:a, :b])
    end
  end

  describe "#validate!" do
    describe "referential integrity" do
      it "passes when all referenced topics exist" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: :b)
        graph.add_topic(build_topic(:b))

        expect { graph.validate! }.not_to raise_error
      end

      it "fails when referencing undefined topic" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: :undefined)

        expect {
          graph.validate!
        }.to raise_error(RSpec::Agents::UndefinedTopicError, /:a references undefined topic :undefined/)
      end

      it "fails when topic used but never defined" do
        graph = described_class.new
        graph.use_topic(:greeting, next_topics: :gathering)
        graph.add_topic(build_topic(:gathering))

        expect {
          graph.validate!
        }.to raise_error(RSpec::Agents::UndefinedTopicError, /:greeting.*never defined/)
      end
    end

    describe "self-loop detection" do
      it "fails on explicit self-loop" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: :a)

        expect {
          graph.validate!
        }.to raise_error(RSpec::Agents::SelfLoopError, /:a has a self-loop/)
      end

      it "passes when no self-loops" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: :b)
        graph.add_topic(build_topic(:b), next_topics: :a)  # Cycle is OK, self-loop is not

        expect { graph.validate! }.not_to raise_error
      end
    end

    describe "connectivity" do
      it "passes when all topics reachable from initial" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: [:b, :c])
        graph.add_topic(build_topic(:b))
        graph.add_topic(build_topic(:c))

        expect { graph.validate! }.not_to raise_error
      end

      it "fails when topic unreachable" do
        graph = described_class.new
        graph.add_topic(build_topic(:a), next_topics: :b)
        graph.add_topic(build_topic(:b))
        graph.add_topic(build_topic(:orphan))  # Not connected

        expect {
          graph.validate!
        }.to raise_error(RSpec::Agents::UnreachableTopicError, /:orphan.*not reachable/)
      end

      it "passes for empty graph" do
        graph = described_class.new
        expect { graph.validate! }.not_to raise_error
      end
    end

    describe "wiring successors" do
      it "sets successor arrays on topics" do
        graph = described_class.new
        topic_a = build_topic(:a)
        topic_b = build_topic(:b)

        graph.add_topic(topic_a, next_topics: :b)
        graph.add_topic(topic_b)
        graph.validate!

        expect(topic_a.successors).to eq([:b])
        expect(topic_b.successors).to eq([])
      end
    end
  end

  describe "#successors_of" do
    it "returns successor topic names" do
      graph = described_class.new
      graph.add_topic(build_topic(:a), next_topics: [:b, :c])
      graph.add_topic(build_topic(:b))
      graph.add_topic(build_topic(:c))

      expect(graph.successors_of(:a)).to eq([:b, :c])
    end

    it "returns empty array for terminal topics" do
      graph = described_class.new
      graph.add_topic(build_topic(:terminal))

      expect(graph.successors_of(:terminal)).to eq([])
    end

    it "returns empty array for unknown topics" do
      graph = described_class.new
      expect(graph.successors_of(:unknown)).to eq([])
    end
  end

  describe "#reachable_from?" do
    let(:graph) do
      g = described_class.new
      g.add_topic(build_topic(:a), next_topics: [:b, :c])
      g.add_topic(build_topic(:b), next_topics: :d)
      g.add_topic(build_topic(:c))
      g.add_topic(build_topic(:d))
      g.validate!
      g
    end

    it "returns true for directly connected topics" do
      expect(graph.reachable_from?(:a, :b)).to be true
    end

    it "returns true for transitively connected topics" do
      expect(graph.reachable_from?(:a, :d)).to be true
    end

    it "returns false for unreachable topics" do
      expect(graph.reachable_from?(:c, :d)).to be false
    end

    it "returns true when start equals target" do
      expect(graph.reachable_from?(:a, :a)).to be true
    end
  end

  describe "#[]" do
    it "returns topic by name" do
      graph = described_class.new
      topic = build_topic(:greeting)
      graph.add_topic(topic)

      expect(graph[:greeting]).to eq(topic)
    end

    it "returns nil for unknown topic" do
      graph = described_class.new
      expect(graph[:unknown]).to be_nil
    end

    it "accepts string names" do
      graph = described_class.new
      topic = build_topic(:greeting)
      graph.add_topic(topic)

      expect(graph["greeting"]).to eq(topic)
    end
  end

  describe "#topic_names" do
    it "returns all topic names" do
      graph = described_class.new
      graph.add_topic(build_topic(:a))
      graph.add_topic(build_topic(:b))

      expect(graph.topic_names).to contain_exactly(:a, :b)
    end
  end

  describe "#terminal_topics" do
    it "returns topics with no successors" do
      graph = described_class.new
      graph.add_topic(build_topic(:a), next_topics: :b)
      graph.add_topic(build_topic(:b), next_topics: :c)
      graph.add_topic(build_topic(:c))
      graph.validate!

      expect(graph.terminal_topics).to eq([:c])
    end
  end

  describe "#size" do
    it "returns number of topics" do
      graph = described_class.new
      graph.add_topic(build_topic(:a))
      graph.add_topic(build_topic(:b))

      expect(graph.size).to eq(2)
    end
  end

  describe "complex graph example" do
    it "validates event booking flow from design doc" do
      graph = described_class.new

      graph.add_topic(build_topic(:greeting) {
        characteristic "Initial contact phase"
      }, next_topics: :gathering_details)

      graph.add_topic(build_topic(:gathering_details) {
        characteristic "Collecting event requirements"
      }, next_topics: :presenting_results)

      graph.add_topic(build_topic(:presenting_results) {
        characteristic "Presenting venue options"
        triggers { on_tool_call :search_suppliers }
      }, next_topics: [:gathering_details, :booking_confirmation])

      graph.add_topic(build_topic(:booking_confirmation) {
        characteristic "Confirming the booking"
        triggers { on_tool_call :book_venue }
      })

      expect { graph.validate! }.not_to raise_error
      expect(graph.initial_topic).to eq(:greeting)
      expect(graph.terminal_topics).to eq([:booking_confirmation])
      expect(graph.reachable_from?(:greeting, :booking_confirmation)).to be true
    end
  end
end

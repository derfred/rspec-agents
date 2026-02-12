# frozen_string_literal: true

require "spec_helper"
require "rspec/agents/parallel/example_discovery"
require "rspec/agents/parallel/controller"
require "tempfile"
require "async"

RSpec.describe "Parallel mode error handling", type: :integration do
  let(:temp_dir) { Dir.mktmpdir("rspec_agents_test") }

  after do
    FileUtils.rm_rf(temp_dir) if temp_dir && File.exist?(temp_dir)
  end

  describe "ExampleDiscovery error reporting" do
    context "when spec file has syntax error" do
      let(:syntax_error_spec) do
        File.join(temp_dir, "syntax_error_spec.rb")
      end

      before do
        File.write(syntax_error_spec, <<~RUBY)
          # frozen_string_literal: true

          RSpec.describe "Broken spec" do
            it "has a syntax error" do
              def broken_method
                puts "missing end keyword"
            end
          end
        RUBY
      end

      it "raises DiscoveryError with helpful message" do
        expect {
          RSpec::Agents::Parallel::ExampleDiscovery.discover([syntax_error_spec])
        }.to raise_error(
          RSpec::Agents::Parallel::ExampleDiscovery::DiscoveryError,
          /Failed to load spec files: 1 error\(s\) occurred during loading/
        )
      end

      it "suggests running specs directly to see detailed errors" do
        expect {
          RSpec::Agents::Parallel::ExampleDiscovery.discover([syntax_error_spec])
        }.to raise_error(
          RSpec::Agents::Parallel::ExampleDiscovery::DiscoveryError,
          /Try running the specs directly with 'bundle exec rspec/
        )
      end
    end

    context "when spec file has missing dependency" do
      let(:missing_dep_spec) do
        File.join(temp_dir, "missing_dep_spec.rb")
      end

      before do
        File.write(missing_dep_spec, <<~RUBY)
          # frozen_string_literal: true
          require "nonexistent_library_12345"

          RSpec.describe "Spec with missing dependency" do
            it "works" do
              expect(true).to be true
            end
          end
        RUBY
      end

      it "raises DiscoveryError for LoadError" do
        expect {
          RSpec::Agents::Parallel::ExampleDiscovery.discover([missing_dep_spec])
        }.to raise_error(
          RSpec::Agents::Parallel::ExampleDiscovery::DiscoveryError,
          /Failed to load spec files: 1 error\(s\) occurred during loading/
        )
      end
    end

    context "when spec file is valid" do
      let(:valid_spec) do
        File.join(temp_dir, "valid_spec.rb")
      end

      before do
        File.write(valid_spec, <<~RUBY)
          # frozen_string_literal: true

          RSpec.describe "Valid spec" do
            it "works correctly" do
              expect(1 + 1).to eq(2)
            end

            it "has another example" do
              expect("hello").to be_a(String)
            end
          end
        RUBY
      end

      it "successfully discovers examples" do
        examples = RSpec::Agents::Parallel::ExampleDiscovery.discover([valid_spec])

        expect(examples).to be_an(Array)
        expect(examples.size).to eq(2)
        expect(examples.first).to be_a(RSpec::Agents::Parallel::ExampleRef)
        expect(examples.first.location).to include(valid_spec)
      end
    end
  end

  describe "ParallelSpecController error propagation" do
    context "when discovery fails due to syntax error" do
      let(:syntax_error_spec) do
        File.join(temp_dir, "syntax_error_spec.rb")
      end

      before do
        File.write(syntax_error_spec, <<~RUBY)
          # frozen_string_literal: true

          RSpec.describe "Broken" do
            it "fails" do
              def broken
                # Missing end
            end
          end
        RUBY
      end

      it "returns RunResult with error message" do
        controller = RSpec::Agents::Parallel::ParallelSpecController.new(
          worker_count: 2,
          fail_fast:    false
        )

        controller.start([syntax_error_spec])

        Async do |task|
          controller.execute(task: task)
        end

        result = controller.results

        expect(result.success?).to be false
        expect(result.error).to match(/Example discovery failed/)
        expect(result.error).to match(/Failed to load spec files: 1 error\(s\) occurred/)
      end

      it "sets controller status to failed" do
        controller = RSpec::Agents::Parallel::ParallelSpecController.new(
          worker_count: 2,
          fail_fast:    false
        )

        controller.start([syntax_error_spec])

        Async do |task|
          controller.execute(task: task)
        end

        expect(controller.status).to eq(:failed)
      end
    end

    context "when specs are valid" do
      let(:valid_spec) do
        File.join(temp_dir, "valid_spec.rb")
      end

      before do
        # Write a minimal valid spec that doesn't require agents_helper
        File.write(valid_spec, <<~RUBY)
          # frozen_string_literal: true

          RSpec.describe "Simple spec" do
            it "passes" do
              expect(true).to be true
            end
          end
        RUBY
      end

      it "executes successfully" do
        controller = RSpec::Agents::Parallel::ParallelSpecController.new(
          worker_count: 2,
          fail_fast:    false
        )

        controller.start([valid_spec])

        Async do |task|
          controller.execute(task: task)
        end

        result = controller.results

        expect(result.success?).to be true
        expect(result.error).to be_nil
        expect(result.example_count).to eq(1)
      end
    end
  end

  describe "CLI integration" do
    context "when running parallel mode with syntax error" do
      let(:syntax_error_spec) do
        File.join(temp_dir, "syntax_error_spec.rb")
      end

      before do
        File.write(syntax_error_spec, <<~RUBY)
          # frozen_string_literal: true

          RSpec.describe "Broken" do
            it "fails" do
              def broken
                # Missing end
            end
          end
        RUBY
      end

      it "displays error message to user" do
        # Run the CLI and capture output
        output = `bin/rspec-agents parallel -w 2 #{syntax_error_spec} 2>&1`

        expect(output).to match(/Error:.*Example discovery failed/)
        expect(output).to match(/Failed to load spec files: 1 error\(s\) occurred/)
        expect(output).to match(/Try running the specs directly/)
        expect($?.exitstatus).to eq(1)
      end
    end
  end
end

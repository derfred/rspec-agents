# frozen_string_literal: true

$:.push File.expand_path("../lib", __FILE__)
require "rspec/agents/version"

Gem::Specification.new do |s|
  s.name        = "rspec-agents"
  s.version     = RSpec::Agents::VERSION
  s.authors     = ["Frederik Fix"]
  s.email       = ["ich@derfred.com"]
  s.homepage    = "https://github.com/derfred/rspec-agents"
  s.summary     = "RSpec testing framework for AI agent conversations"
  s.description = "A testing framework for chatbot and AI agent conversations, providing DSL, matchers, parallel execution, and HTML reporting."
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.3"

  s.files         = Dir["lib/**/*", "bin/*"]
  s.bindir        = "bin"
  s.executables   = ["rspec-agents"]
  s.require_paths = ["lib"]

  s.add_dependency "async", ">= 2.0"
  s.add_dependency "rspec-core", ">= 3.0"
  s.add_dependency "tilt", ">= 2.0"
  s.add_dependency "haml", ">= 6.0"

  s.add_development_dependency "rspec", "~> 3.12"
  s.add_development_dependency "async-rspec"
  s.add_development_dependency "rake"
end

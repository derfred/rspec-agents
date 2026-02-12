# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/**/*_spec.rb"
end

desc "Run Playwright tests"
task :playwright do
  Dir.chdir("spec/playwright") do
    sh "npm test"
  end
end

desc "Install Playwright dependencies"
task :playwright_install do
  Dir.chdir("spec/playwright") do
    sh "npm ci"
    sh "npx playwright install --with-deps"
  end
end

desc "Run Playwright tests with UI"
task "playwright:ui" do
  Dir.chdir("spec/playwright") do
    sh "npm run test:ui"
  end
end

desc "Run Playwright tests in debug mode"
task "playwright:debug" do
  Dir.chdir("spec/playwright") do
    sh "npm run test:debug"
  end
end

desc "Generate Playwright test fixtures"
task "playwright:fixtures" do
  Dir.chdir("spec/playwright") do
    sh "npm run generate-fixtures"
  end
end

desc "Run all tests (RSpec and Playwright)"
task "test:all" => [:spec, :playwright]

task default: :spec

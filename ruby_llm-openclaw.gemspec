# frozen_string_literal: true

require_relative "lib/ruby_llm/providers/openclaw/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-openclaw"
  spec.version = RubyLLM::Providers::OpenClawVersion::VERSION
  spec.authors = ["Kieran Klaassen"]
  spec.email = ["kieran@kiskolabs.com"]

  spec.summary = "OpenClaw provider for RubyLLM"
  spec.description = "Routes RubyLLM chat completions to an OpenClaw Gateway via WebSocket."
  spec.homepage = "https://github.com/kieranklaassen/ruby_llm-openclaw"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["*.{md,txt}", "{lib}/**/*"]
  spec.require_path = "lib"

  spec.add_dependency "ruby_llm", ">= 1.12"
  spec.add_dependency "async-websocket", "~> 0.30"
  spec.add_dependency "ed25519", "~> 1.3"
end

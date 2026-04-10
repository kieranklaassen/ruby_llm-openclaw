# frozen_string_literal: true

# Standard library
require "digest"
require "fileutils"
require "securerandom"
require "base64"

# External dependencies
require "ruby_llm"
require "ed25519"
require "async"
require "async/http/endpoint"
require "async/websocket/client"

# Internal files
require_relative "ruby_llm/providers/openclaw/version"
require_relative "ruby_llm/providers/openclaw/chat"
require_relative "ruby_llm/providers/openclaw/client"
require_relative "ruby_llm/providers/openclaw"

# Configuration extension
RubyLLM::Configuration.class_eval do
  attr_accessor :openclaw_url, :openclaw_token, :openclaw_signing_key
end

# Set defaults
RubyLLM.config.openclaw_url = "ws://localhost:18789"

# Register provider
RubyLLM::Provider.register :openclaw, RubyLLM::Providers::OpenClaw

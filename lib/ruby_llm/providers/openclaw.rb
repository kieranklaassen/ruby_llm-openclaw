# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenClaw < Provider
      VERSION = OpenClawVersion::VERSION

      # Error hierarchy
      class Error < StandardError; end
      class ConnectionError < Error; end
      class AuthenticationError < Error; end
      class TimeoutError < Error; end

      # Override initialize to skip Faraday Connection creation.
      # Base Provider#initialize creates Connection.new(self, @config) which
      # calls Faraday.new(provider.api_base) — that would point Faraday at
      # a ws:// URL and fail. We bypass HTTP entirely.
      def initialize(config)
        @config = config
        ensure_configured!
      end

      def api_base
        @config.openclaw_url || "ws://localhost:18789"
      end

      def headers
        {}
      end

      def list_models
        []
      end

      class << self
        def configuration_requirements
          %i[openclaw_url openclaw_token]
        end

        def assume_models_exist?
          true
        end

        def capabilities
          nil
        end
      end
    end
  end
end

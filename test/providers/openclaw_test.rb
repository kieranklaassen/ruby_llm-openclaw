# frozen_string_literal: true

require "test_helper"

class OpenClawProviderTest < Minitest::Test
  def test_version
    assert_equal "0.1.0", RubyLLM::Providers::OpenClaw::VERSION
  end

  def test_provider_registered
    assert_equal RubyLLM::Providers::OpenClaw, RubyLLM::Provider.resolve(:openclaw)
  end

  def test_assume_models_exist
    assert RubyLLM::Providers::OpenClaw.assume_models_exist?
  end

  def test_capabilities_nil
    assert_nil RubyLLM::Providers::OpenClaw.capabilities
  end

  def test_configuration_requirements
    assert_equal %i[openclaw_url openclaw_token], RubyLLM::Providers::OpenClaw.configuration_requirements
  end

  def test_configuration_extension
    config = RubyLLM.config
    assert_respond_to config, :openclaw_url
    assert_respond_to config, :openclaw_url=
    assert_respond_to config, :openclaw_token
    assert_respond_to config, :openclaw_token=
  end

  def test_default_url
    assert_equal "ws://localhost:18789", RubyLLM.config.openclaw_url
  end

  def test_configure_block
    original_url = RubyLLM.config.openclaw_url
    original_token = RubyLLM.config.openclaw_token

    RubyLLM.configure do |config|
      config.openclaw_url = "wss://example.com:18789"
      config.openclaw_token = "test-token"
    end

    assert_equal "wss://example.com:18789", RubyLLM.config.openclaw_url
    assert_equal "test-token", RubyLLM.config.openclaw_token
  ensure
    RubyLLM.config.openclaw_url = original_url
    RubyLLM.config.openclaw_token = original_token
  end

  def test_initialize_skips_faraday_connection
    RubyLLM.config.openclaw_token = "test-token"
    provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)

    assert_nil provider.connection
    assert_equal RubyLLM.config, provider.config
  ensure
    RubyLLM.config.openclaw_token = nil
  end

  def test_initialize_raises_without_config
    RubyLLM.config.openclaw_token = nil
    RubyLLM.config.openclaw_url = nil

    assert_raises(RubyLLM::ConfigurationError) do
      RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
    end
  ensure
    RubyLLM.config.openclaw_url = "ws://localhost:18789"
  end

  def test_api_base
    RubyLLM.config.openclaw_token = "test-token"
    provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)

    assert_equal "ws://localhost:18789", provider.api_base
  ensure
    RubyLLM.config.openclaw_token = nil
  end

  def test_list_models_returns_empty
    RubyLLM.config.openclaw_token = "test-token"
    provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)

    assert_equal [], provider.list_models
  ensure
    RubyLLM.config.openclaw_token = nil
  end

  def test_headers_empty
    RubyLLM.config.openclaw_token = "test-token"
    provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)

    assert_equal({}, provider.headers)
  ensure
    RubyLLM.config.openclaw_token = nil
  end

  def test_slug
    assert_equal "openclaw", RubyLLM::Providers::OpenClaw.slug
  end

  def test_error_class_hierarchy
    oc = RubyLLM::Providers::OpenClaw
    assert oc::Error < StandardError
    assert oc::ConnectionError < oc::Error
    assert oc::AuthenticationError < oc::Error
    assert oc::TimeoutError < oc::Error
  end
end

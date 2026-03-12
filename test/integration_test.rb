# frozen_string_literal: true

require "test_helper"

class IntegrationTest < Minitest::Test
  def test_full_sync_flow
    configure_openclaw do
      stub_client(events: [
        { "content" => "Hello from OpenClaw!", "model" => "gpt-4.1", "usage" => { "input_tokens" => 12, "output_tokens" => 6 } }
      ]) do
        provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
        model = mock_model("openclaw/my-agent")

        result = provider.complete(
          [RubyLLM::Message.new(role: :user, content: "Hello")],
          tools: {},
          temperature: nil,
          model: model
        )

        assert_instance_of RubyLLM::Message, result
        assert_equal :assistant, result.role
        assert_equal "Hello from OpenClaw!", result.content
        assert_equal "gpt-4.1", result.model_id
        assert_equal 12, result.input_tokens
        assert_equal 6, result.output_tokens
      end
    end
  end

  def test_full_streaming_flow
    configure_openclaw do
      stub_client(events: [
        { "content" => "Streaming ", "model" => "gpt-4.1" },
        { "content" => "works!", "model" => "gpt-4.1" }
      ]) do
        provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
        model = mock_model("openclaw/my-agent")

        chunks = []
        result = provider.complete(
          [RubyLLM::Message.new(role: :user, content: "Test streaming")],
          tools: {},
          temperature: nil,
          model: model
        ) { |chunk| chunks << chunk }

        # Chunks yielded correctly
        assert_equal 2, chunks.size
        assert_equal "Streaming ", chunks[0].content
        assert_equal "works!", chunks[1].content

        # Final message accumulated
        assert_equal "Streaming works!", result.content
      end
    end
  end

  def test_multi_turn_conversation
    configure_openclaw do
      captured_messages = nil
      stub_client(
        events: [{ "content" => "Follow-up answer" }],
        capture_messages: ->(m) { captured_messages = m }
      ) do
        provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
        model = mock_model("openclaw/my-agent")

        messages = [
          RubyLLM::Message.new(role: :user, content: "First question"),
          RubyLLM::Message.new(role: :assistant, content: "First answer"),
          RubyLLM::Message.new(role: :user, content: "Second question")
        ]

        provider.complete(messages, tools: {}, temperature: nil, model: model)

        # Full history sent
        assert_equal 3, captured_messages.size
        assert_equal({ role: "user", content: "First question" }, captured_messages[0])
        assert_equal({ role: "assistant", content: "First answer" }, captured_messages[1])
        assert_equal({ role: "user", content: "Second question" }, captured_messages[2])
      end
    end
  end

  def test_provider_registration_resolves
    assert_equal RubyLLM::Providers::OpenClaw, RubyLLM::Provider.resolve(:openclaw)
  end

  def test_assume_models_exist_resolves_any_model
    assert RubyLLM::Providers::OpenClaw.assume_models_exist?
  end

  def test_agent_name_extracted_from_model_id
    configure_openclaw do
      captured_agent = nil
      stub_client(
        events: [{ "content" => "OK" }],
        capture_agent: ->(a) { captured_agent = a }
      ) do
        provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
        provider.complete(
          [RubyLLM::Message.new(role: :user, content: "Hi")],
          tools: {},
          temperature: nil,
          model: mock_model("openclaw/production-assistant")
        )
      end

      assert_equal "production-assistant", captured_agent
    end
  end

  def test_configuration_error_without_token
    RubyLLM.config.openclaw_token = nil

    assert_raises(RubyLLM::ConfigurationError) do
      RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
    end
  ensure
    RubyLLM.config.openclaw_token = nil
  end

  private

  def configure_openclaw
    original_token = RubyLLM.config.openclaw_token
    RubyLLM.config.openclaw_token = "test-integration-token"
    yield
  ensure
    RubyLLM.config.openclaw_token = original_token
  end

  def mock_model(id)
    model = Object.new
    model.define_singleton_method(:id) { id }
    model
  end

  def stub_client(events:, capture_messages: nil, capture_agent: nil)
    fake_client_class = Class.new do
      define_method(:initialize) { |_config, **_opts| }
      define_method(:chat_send) do |messages, agent:, &block|
        capture_messages&.call(messages)
        capture_agent&.call(agent)
        events.each { |event| block&.call(event) }
      end
    end

    original_client = RubyLLM::Providers::OpenClaw::Client
    RubyLLM::Providers::OpenClaw.send(:remove_const, :Client)
    RubyLLM::Providers::OpenClaw.const_set(:Client, fake_client_class)
    yield
  ensure
    RubyLLM::Providers::OpenClaw.send(:remove_const, :Client)
    RubyLLM::Providers::OpenClaw.const_set(:Client, original_client)
  end
end

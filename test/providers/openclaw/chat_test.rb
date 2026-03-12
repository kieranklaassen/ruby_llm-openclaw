# frozen_string_literal: true

require "test_helper"

class OpenClawChatTest < Minitest::Test
  def setup
    RubyLLM.config.openclaw_token = "test-token"
    @provider = RubyLLM::Providers::OpenClaw.new(RubyLLM.config)
  end

  def teardown
    RubyLLM.config.openclaw_token = nil
  end

  # -- complete (sync) --

  def test_complete_returns_message
    stub_client(events: [{ "content" => "Hello back!", "model" => "gpt-4" }]) do
      result = call_complete([user_message("Hi")])

      assert_instance_of RubyLLM::Message, result
      assert_equal :assistant, result.role
      assert_equal "Hello back!", result.content
    end
  end

  def test_complete_accumulates_multiple_chunks
    events = [
      { "content" => "Hello ", "model" => "gpt-4" },
      { "content" => "world!", "model" => "gpt-4" }
    ]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])

      assert_equal "Hello world!", result.content
    end
  end

  def test_complete_tracks_token_usage
    events = [
      { "content" => "Hi", "model" => "gpt-4", "usage" => { "input_tokens" => 10, "output_tokens" => 5 } }
    ]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])

      assert_equal 10, result.input_tokens
      assert_equal 5, result.output_tokens
    end
  end

  # -- complete (streaming) --

  def test_streaming_yields_chunks
    events = [
      { "content" => "Hello ", "model" => "gpt-4" },
      { "content" => "world!", "model" => "gpt-4" }
    ]

    chunks = []
    stub_client(events: events) do
      call_complete([user_message("Hi")]) { |chunk| chunks << chunk }
    end

    assert_equal 2, chunks.size
    assert_instance_of RubyLLM::Chunk, chunks.first
    assert_equal "Hello ", chunks[0].content
    assert_equal "world!", chunks[1].content
  end

  def test_streaming_still_returns_accumulated_message
    events = [
      { "content" => "Hello ", "model" => "gpt-4" },
      { "content" => "world!", "model" => "gpt-4" }
    ]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")]) { |_chunk| }

      assert_equal "Hello world!", result.content
    end
  end

  # -- render_messages --

  def test_sends_full_message_history
    messages = [
      user_message("First question"),
      assistant_message("First answer"),
      user_message("Follow up")
    ]

    captured_messages = nil
    stub_client(events: [{ "content" => "OK" }], capture_messages: ->(m) { captured_messages = m }) do
      call_complete(messages)
    end

    assert_equal 3, captured_messages.size
    assert_equal "user", captured_messages[0][:role]
    assert_equal "First question", captured_messages[0][:content]
    assert_equal "assistant", captured_messages[1][:role]
    assert_equal "First answer", captured_messages[1][:content]
    assert_equal "user", captured_messages[2][:role]
    assert_equal "Follow up", captured_messages[2][:content]
  end

  # -- model ID prefix stripping --

  def test_strips_openclaw_prefix_from_model_id
    captured_agent = nil
    stub_client(events: [{ "content" => "OK" }], capture_agent: ->(a) { captured_agent = a }) do
      call_complete([user_message("Hi")], model_id: "openclaw/my-agent")
    end

    assert_equal "my-agent", captured_agent
  end

  def test_handles_model_without_prefix
    captured_agent = nil
    stub_client(events: [{ "content" => "OK" }], capture_agent: ->(a) { captured_agent = a }) do
      call_complete([user_message("Hi")], model_id: "my-agent")
    end

    assert_equal "my-agent", captured_agent
  end

  # -- unsupported params warnings --

  def test_warns_on_tools
    events = [{ "content" => "OK" }]
    output = nil

    stub_client(events: events) do
      output = capture_io { call_complete([user_message("Hi")], tools: { tool1: "def" }) }.last
    end

    assert_match(/tools.*ignored/i, output)
  end

  def test_warns_on_temperature
    events = [{ "content" => "OK" }]
    output = nil

    stub_client(events: events) do
      output = capture_io { call_complete([user_message("Hi")], temperature: 0.7) }.last
    end

    assert_match(/temperature.*ignored/i, output)
  end

  def test_warns_on_schema
    events = [{ "content" => "OK" }]
    output = nil

    stub_client(events: events) do
      output = capture_io { call_complete([user_message("Hi")], schema: { type: "object" }) }.last
    end

    assert_match(/schema.*ignored/i, output)
  end

  def test_warns_on_thinking
    events = [{ "content" => "OK" }]
    output = nil

    stub_client(events: events) do
      output = capture_io { call_complete([user_message("Hi")], thinking: { budget_tokens: 1000 }) }.last
    end

    assert_match(/thinking.*ignored/i, output)
  end

  def test_no_warning_without_unsupported_params
    events = [{ "content" => "OK" }]
    output = nil

    stub_client(events: events) do
      output = capture_io { call_complete([user_message("Hi")]) }.last
    end

    refute_match(/ignored/i, output)
  end

  # -- build_chunk --

  def test_build_chunk_with_content_key
    events = [{ "content" => "Hello", "model" => "gpt-4" }]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])
      assert_equal "Hello", result.content
    end
  end

  def test_build_chunk_with_text_key
    events = [{ "text" => "Hello", "model" => "gpt-4" }]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])
      assert_equal "Hello", result.content
    end
  end

  def test_build_chunk_with_nil_content
    events = [{ "model" => "gpt-4" }]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])
      assert_nil result.content
    end
  end

  def test_build_chunk_model_id
    events = [{ "content" => "Hi", "model" => "claude-3" }]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])
      assert_equal "claude-3", result.model_id
    end
  end

  def test_build_chunk_fallback_model_id
    events = [{ "content" => "Hi" }]

    stub_client(events: events) do
      result = call_complete([user_message("Hi")])
      assert_equal "openclaw", result.model_id
    end
  end

  private

  def user_message(content)
    RubyLLM::Message.new(role: :user, content: content)
  end

  def assistant_message(content)
    RubyLLM::Message.new(role: :assistant, content: content)
  end

  def model_info(id = "openclaw/test-agent")
    info = Object.new
    info.define_singleton_method(:id) { id }
    info
  end

  def call_complete(messages, model_id: "openclaw/test-agent", tools: {}, temperature: nil, schema: nil, thinking: nil, &block)
    @provider.complete(
      messages,
      tools: tools,
      temperature: temperature,
      model: model_info(model_id),
      schema: schema,
      thinking: thinking,
      &block
    )
  end

  # Stubs Client.new to yield fake events instead of connecting to WebSocket
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

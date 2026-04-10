# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenClaw < Provider
      module Chat
        def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &block) # rubocop:disable Metrics/ParameterLists,Lint/UnusedMethodArgument
          warn_unsupported_params(tools: tools, temperature: temperature, schema: schema, thinking: thinking)

          signing_key = @config.respond_to?(:openclaw_signing_key) ? @config.openclaw_signing_key : nil
          client = Client.new(@config, signing_key: signing_key)
          accumulator = RubyLLM::StreamAccumulator.new
          agent_name = model.id.delete_prefix("openclaw/")

          client.chat_send(render_messages(messages), agent: agent_name) do |event_data|
            chunk = build_chunk(event_data)
            accumulator.add(chunk)
            block&.call(chunk)
          end

          accumulator.to_message(nil)
        end

        private

        def build_chunk(event_data)
          RubyLLM::Chunk.new(
            role: :assistant,
            model_id: event_data["model"] || "openclaw",
            content: event_data["content"] || event_data["text"],
            input_tokens: event_data.dig("usage", "input_tokens"),
            output_tokens: event_data.dig("usage", "output_tokens")
          )
        end

        def render_messages(messages)
          messages.map { |m| { role: m.role.to_s, content: m.content.to_s } }
        end

        def warn_unsupported_params(tools:, temperature:, schema:, thinking:)
          warn "[ruby_llm-openclaw] tools: parameter ignored (OpenClaw manages tools server-side)" if tools.respond_to?(:any?) && tools.any?
          warn "[ruby_llm-openclaw] temperature: parameter ignored" if temperature
          warn "[ruby_llm-openclaw] schema: parameter ignored" if schema
          warn "[ruby_llm-openclaw] thinking: parameter ignored" if thinking
        end
      end
    end
  end
end

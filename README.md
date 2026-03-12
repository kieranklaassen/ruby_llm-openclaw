# RubyLLM::OpenClaw

OpenClaw provider for [RubyLLM](https://github.com/crmne/ruby_llm). Routes chat completions to an OpenClaw Gateway via WebSocket.

[![Gem Version](https://img.shields.io/gem/v/ruby_llm-openclaw)](https://rubygems.org/gems/ruby_llm-openclaw)
[![Build Status](https://github.com/<user>/ruby_llm-openclaw/actions/workflows/ci.yml/badge.svg)](https://github.com/<user>/ruby_llm-openclaw/actions)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE.txt)

## Installation

Add this line to your application's **Gemfile**:

```ruby
gem "ruby_llm-openclaw"
```

Ruby 3.1+ required.

## Prerequisites: OpenClaw Gateway

Install and start the [OpenClaw](https://docs.openclaw.ai) Gateway:

```bash
npm install -g openclaw@latest
openclaw onboard --install-daemon
```

The wizard configures your LLM provider, gateway auth, and installs the daemon service. The gateway listens on `ws://127.0.0.1:18789` by default.

See [docs/GATEWAY_SETUP.md](docs/GATEWAY_SETUP.md) for detailed setup, remote access, and non-interactive (server/CI) instructions.

## Configuration

```ruby
RubyLLM.configure do |config|
  config.openclaw_url = "ws://localhost:18789"
  config.openclaw_token = ENV["OPENCLAW_GATEWAY_TOKEN"]
end
```

The default URL is `ws://localhost:18789`.

## Usage

Any `openclaw/` model ID works — agents resolve on demand.

Use the Gateway's default claw or specify one by name.

```ruby
# Default claw
chat = RubyLLM.chat(model: "openclaw")

# Specific claw
chat = RubyLLM.chat(model: "openclaw/my-agent")
```

### Streaming

```ruby
chat.ask("Summarize my inbox") { |chunk| print chunk.content }
```

### Multi-Turn

Full message history is sent on each request.

```ruby
chat = RubyLLM.chat(model: "openclaw/my-agent")
chat.ask("Summarize my inbox")
chat.ask("What about last week?")
```

## How It Works

The gem registers as a RubyLLM provider. It overrides `complete` to use WebSocket instead of HTTP.

- Connects to the OpenClaw Gateway via WebSocket
- Authenticates with Ed25519 challenge-response
- Sends messages via `chat.send`
- Streams response chunks back to RubyLLM

### Device Identity

An Ed25519 keypair is auto-generated on first use. It is stored at `~/.ruby_llm/openclaw/device.key` with `0600` permissions. Local (loopback) connections auto-approve device pairing.

### Unsupported Parameters

OpenClaw manages these server-side. Passing them logs a warning.

- `tools`
- `temperature`
- `schema`
- `thinking`

## Security

- Warns on `ws://` to non-loopback addresses
- Device key stored with `0600` permissions
- Agent names validated against `/\A[a-zA-Z0-9_-]+\z/`
- Use `wss://` for production deployments

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/<user>/ruby_llm-openclaw/issues)
- Fix bugs and [submit pull requests](https://github.com/<user>/ruby_llm-openclaw/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).

# Brainstorm: RubyLLM OpenClaw Provider Gem

**Date:** 2026-03-11
**Status:** Complete
**Participants:** Kieran, Claude

## What We're Building

A standalone Ruby gem (`ruby_llm-openclaw`) that registers OpenClaw as a RubyLLM provider. This lets any RubyLLM chat route to a remote OpenClaw agent instance:

```ruby
# Configuration
RubyLLM.configure do |config|
  config.openclaw_url = "ws://localhost:18789"
  config.openclaw_token = ENV["OPENCLAW_GATEWAY_TOKEN"]
end

# Usage — identical to any other RubyLLM provider
chat = RubyLLM.chat(model: "openclaw/my-agent")
chat.ask("Summarize my inbox") # synchronous, returns response

# Streaming
chat.ask("Summarize my inbox") { |chunk| print chunk.content }
```

The OpenClaw instance is pre-configured with its own agents, tools, and models. The Ruby gem is purely a **transport layer** — it connects as a Gateway WebSocket client, sends messages, and streams responses back. Agent configuration lives on the OpenClaw side.

## Why This Approach

### RubyLLM Provider (vs. standalone agent class)
- Fits the existing RubyLLM ecosystem — no new API to learn
- Can swap between direct LLM calls and OpenClaw-routed calls without changing app code
- Benefits from RubyLLM's persistence (`acts_as_chat`), tool chaining, and instrumentation for free

### Gateway WebSocket Client (not a channel)
- **No OpenClaw-side changes needed** — the gem connects as a client (like the CLI or web UI do), not as a channel (like Slack/Discord)
- OpenClaw's Gateway exposes a single WebSocket control plane at `ws://127.0.0.1:18789` for all clients
- Protocol: JSON-over-WebSocket with `req`/`res`/`event` message types
- `chat.send` method for sending messages, response events for receiving
- Natural fit for streaming (chunks arrive as WebSocket frames)

### Standalone Gem (vs. internal to Cora)
- Clean separation of concerns
- Other Ruby/Rails apps can use it
- Follows the pattern of other RubyLLM provider gems
- Tested against Cora as first consumer

## Key Decisions

1. **Provider, not agent** — Register as `RubyLLM::Provider::OpenClaw` so `model: "openclaw/agent-name"` works
2. **Gateway client, not channel** — Connects to the Gateway WebSocket like the CLI/web UI. No OpenClaw plugin needed
3. **Streaming from day one** — Support RubyLLM's `{ |chunk| }` block pattern via WebSocket events
4. **Transport only** — No agent configuration pass-through; OpenClaw owns its agents, Ruby just talks to them
5. **Connection management** — Persistent WebSocket connection with reconnection logic, not connect-per-request
6. **Agent discovery** — Auto-discover agents via Gateway protocol, with manual config as fallback
7. **Multi-turn sessions** — Maintain OpenClaw session key per RubyLLM chat for conversation continuity
8. **Database-backed connections** — Cora-specific model wraps the gem for storing OpenClaw connections per account (not in the gem itself)
9. **Recommended gems** — `async-websocket` for WebSocket (fiber-based, modern), `ed25519` for device auth (no libsodium needed)

## Gateway Protocol Summary

The OpenClaw Gateway WebSocket protocol works as follows:

### Message Types
- **Request**: `{type: "req", id, method, params}` — client sends
- **Response**: `{type: "res", id, ok, payload|error}` — server replies
- **Event**: `{type: "event", event, payload, seq?}` — server pushes (streaming chunks, etc.)

### Connection Handshake
1. Server sends `connect.challenge` with nonce + timestamp
2. Client sends `connect` request with: device identity, role (`operator`), scopes, auth token, signed nonce
3. Server responds with `hello-ok` including protocol version and policy

### Chat
- `chat.send` method to transmit messages
- Responses arrive as events (streamable)

### Auth
- Token-based via `OPENCLAW_GATEWAY_TOKEN`
- Device identity with cryptographic nonce signing
- Local (loopback) connections auto-approve pairing

## Architecture Sketch

```
┌─────────────────────┐      Gateway WebSocket      ┌──────────────────────┐
│   Ruby/Rails App    │  ◄─────────────────────►    │   OpenClaw Gateway   │
│                     │                              │   ws://host:18789    │
│  RubyLLM.chat(      │   1. Connect + challenge    │                      │
│    model: "openclaw/│   2. Auth (sign nonce) ──►  │   Agent Router       │
│    my-agent"        │   3. chat.send ──►           │     ▼                │
│  ).ask("...")       │   4. ◄── event (chunks)     │   Agent (tools, LLM) │
│                     │   5. ◄── response (done)    │                      │
└─────────────────────┘                              └──────────────────────┘
```

### Gem Structure

```
ruby_llm-openclaw/
├── lib/
│   └── ruby_llm/
│       └── openclaw/
│           ├── provider.rb      # RubyLLM provider registration
│           ├── client.rb        # Gateway WebSocket connection + auth
│           ├── protocol.rb      # Message framing, challenge-response
│           ├── streaming.rb     # Chunk parsing and streaming support
│           └── configuration.rb # URL, token, device identity settings
├── spec/
└── ruby_llm-openclaw.gemspec
```

### Provider Interface

The gem implements RubyLLM's provider contract:
- `complete(messages, tools:, temperature:, model:, &block)` — send via `chat.send`, yield event chunks, return response
- `models` — list available OpenClaw agents as "models"
- Connection pooling for multi-agent setups

## Authentication Deep-Dive

The Gateway uses Ed25519 device authentication. This is well-documented and implementable in Ruby.

### Handshake Flow
1. Server sends `connect.challenge` with `{ nonce: "<uuid>" }`
2. Client builds pipe-delimited payload: `v2|{deviceId}|{clientId}|{clientMode}|{role}|{scopes}|{signedAtMs}|{token}|{nonce}`
3. Client signs payload with Ed25519 private key
4. Client sends `connect` request with device identity, signature, scopes, role
5. Server returns `hello-ok` with `deviceToken` for future connections

### Key Details
- **Keypair**: Ed25519 (32-byte secret, 32-byte public) — Use `ed25519` gem (lightweight, no system deps)
- **Device ID**: `SHA-256(rawPublicKey)` — deterministic from public key
- **Encoding**: base64url for public key and signature
- **Clock skew**: ±2 minutes tolerance on `signedAt`
- **Local auto-pairing**: Loopback connections auto-approve (no manual step needed for dev)
- **Device tokens**: Cached after first pairing; used in future connections instead of shared token

### Ruby Implementation
```ruby
# Pseudocode
require "ed25519"
require "digest"

key = Ed25519::SigningKey.generate  # or load from file
device_id = Digest::SHA256.hexdigest(key.verify_key.to_bytes)
payload = "v2|#{device_id}|ruby_llm|provider|operator|operator.read,operator.write|#{ms_now}|#{token}|#{nonce}"
signature = Base64.urlsafe_encode64(key.sign(payload))
```

## Cora Integration Layer

The gem is pure transport. Cora adds a database-backed model on top:

```ruby
# Cora-specific model (not in the gem)
class OpenclawConnection < ApplicationRecord
  acts_as_tenant :account
  encrypts :token, :device_keypair

  # url:string, token:string, device_keypair:text (encrypted)
  # agents:jsonb (cached from auto-discovery)
  # account_id:bigint

  def to_llm_chat(agent_name)
    RubyLLM.chat(model: "openclaw/#{agent_name}")
    # configures the provider with this connection's credentials
  end
end
```

This allows multi-tenant Cora to store different OpenClaw connections per account, with encrypted credentials.

## Gem Dependencies

```ruby
# ruby_llm-openclaw.gemspec
spec.add_dependency "ruby_llm", ">= 1.12"
spec.add_dependency "async-websocket", "~> 0.30"  # Fiber-based WebSocket client
spec.add_dependency "ed25519", "~> 1.3"            # Ed25519 signing (no libsodium needed)
```

## Resolved Questions

1. **Do we need an OpenClaw plugin?** — No. The gem connects as a Gateway client (like CLI/web UI). No OpenClaw-side changes needed.
2. **WebSocket vs HTTP** — WebSocket via the Gateway protocol. All OpenClaw clients use this same protocol.
3. **Streaming** — Yes, from day one. WebSocket events naturally support streaming chunks.
4. **Scope** — Transport only. OpenClaw owns agent config, Ruby just sends messages and receives responses.
5. **Auth complexity** — Ed25519 signing via the `ed25519` gem. Local connections auto-pair. Not a blocker.
6. **Session management** — Multi-turn. Maintain an OpenClaw session key per RubyLLM chat.
7. **Agent discovery** — Auto-discover via Gateway protocol, manual config as fallback.
8. **WebSocket gem** — `async-websocket` (fiber-based, modern, Ruby 3+ native).
9. **Database backing** — Cora-specific model wraps the gem. Gem stays pure transport.
10. **Keypair persistence** — Gem auto-generates to `~/.ruby_llm/openclaw/device.key` (configurable). Cora stores encrypted in DB per connection.

## Open Questions

None — all questions resolved. Ready for planning.

## References

- [OpenClaw Gateway Protocol](https://docs.openclaw.ai/gateway/protocol)
- [OpenClaw Gateway Configuration](https://docs.openclaw.ai/gateway/configuration)
- [OpenClaw Webhook API](https://docs.openclaw.ai/automation/webhook)
- [OpenClaw Source](https://github.com/openclaw/openclaw)
- [RubyLLM Agent DSL](https://paolino.me/rubyllm-1-12-agents/)
- [OpenClaw Architecture Overview](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)

---
title: "feat: RubyLLM OpenClaw provider gem"
type: feat
status: active
date: 2026-03-11
deepened: 2026-03-12
origin: docs/brainstorms/2026-03-11-ruby-llm-openclaw-provider-brainstorm.md
---

# feat: RubyLLM OpenClaw Provider Gem

## Enhancement Summary

**Deepened on:** 2026-03-12
**Sections enhanced:** All sections
**Research agents used:** architecture-strategist, security-sentinel, performance-oracle, code-simplicity-reviewer, kieran-rails-reviewer, dhh-rails-reviewer, pattern-recognition-specialist, framework-docs-researcher, best-practices-researcher, repo-research-analyst, learnings-researcher, spec-flow-analyzer, andrew-kane-gem-writer

### Key Improvements
1. **Simplified architecture**: 7 source files → 4. Inlined `Streaming`, `Models`, and `DeviceIdentity` into their single consumers.
2. **Connect-per-request for v1**: Eliminated premature connection pooling complexity. Measure first, optimize later.
3. **Critical bug fix**: Must override `initialize` to skip Faraday `Connection` creation (base `Provider` creates a Faraday client pointing at `ws://` URL — will fail).
4. **Critical bug fix**: `messages.last.content` discards conversation history — must send full history or implement session tracking.
5. **Security hardening**: File permissions on keypair, warn on `ws://` to non-loopback, input validation.
6. **Cora integration extracted**: Phase 5 moved to separate plan — different concern, different PR.
7. **Minitest over RSpec**: Matches Cora conventions and Kane gem patterns.

### New Considerations Discovered
- `async-websocket` `Sync` bridge pattern is safe in Puma threads but blocks the thread for the duration of the WebSocket exchange
- ActiveRecord must NOT be called inside `Sync` blocks (fiber/thread connection pool mismatch)
- Base `Provider#initialize` eagerly creates a Faraday `Connection` — must be overridden
- `StreamAccumulator.to_message(nil)` sets `raw: nil` — acceptable, callers should not depend on `raw`
- Post-fork safety: connections must be lazily established per-process (Puma `preload_app!`)
- **Bug**: `model.id` returns `"openclaw/my-agent"` not `"my-agent"` — must strip prefix with `model.id.delete_prefix("openclaw/")`
- **Naming**: Consider `openclaw_api_base` instead of `openclaw_url` to match RubyLLM convention (`openai_api_base`, `ollama_api_base`, etc.)
- **Multi-tenant**: Cora integration must use `RubyLLM.context { |c| c.openclaw_url = ... }` for per-connection config (not global singleton)
- **Unsupported params**: Log warnings when `tools:`, `temperature:`, `schema:`, `thinking:` are passed — OpenClaw handles these server-side
- **DHH insight**: Consider reusing `ConnectedAccount` with `provider: "openclaw"` instead of creating `OpenclawConnection` — same pattern already exists

---

## Overview

Standalone Ruby gem (`ruby_llm-openclaw`) that registers OpenClaw as a RubyLLM provider. Routes chat completions to a remote OpenClaw Gateway via WebSocket, following the same patterns as existing RubyLLM providers (OpenAI, Anthropic, etc.).

```ruby
RubyLLM.configure do |config|
  config.openclaw_url = "ws://localhost:18789"
  config.openclaw_token = ENV["OPENCLAW_GATEWAY_TOKEN"]
end

chat = RubyLLM.chat(model: "openclaw/my-agent")
chat.ask("Summarize my inbox")
chat.ask("Summarize my inbox") { |chunk| print chunk.content }
```

## Problem Statement / Motivation

We want to talk to an OpenClaw agent instance from Ruby/Rails using the same API we use for any other LLM. RubyLLM already abstracts multiple providers behind a unified interface — adding OpenClaw as a provider means zero API changes in consuming code. Swap `model: "gpt-4.1"` for `model: "openclaw/my-agent"` and it just works.

(see brainstorm: `docs/brainstorms/2026-03-11-ruby-llm-openclaw-provider-brainstorm.md`)

## Proposed Solution

Build `ruby_llm-openclaw` following the exact same provider patterns as `RubyLLM::Providers::OpenAI`:

- Provider class inherits from `RubyLLM::Provider`
- Chat module mixed in (Streaming and Models inlined — see simplification rationale below)
- Configuration via `RubyLLM.configure`
- Provider registered with `Provider.register(:openclaw, ...)`
- `assume_models_exist? = true` so any `openclaw/agent-name` model ID resolves

**One deviation**: Override `complete` to use WebSocket (OpenClaw Gateway protocol) instead of Faraday HTTP. This is the only difference — OpenClaw's Gateway doesn't have a synchronous HTTP chat endpoint.

## Technical Approach

### Architecture (Simplified)

```
ruby_llm-openclaw/
├── lib/
│   ├── ruby_llm-openclaw.rb              # Entry point, config extension, register provider
│   └── ruby_llm/
│       └── providers/
│           ├── openclaw.rb                # Provider class, list_models, assume_models_exist?
│           └── openclaw/
│               ├── version.rb            # VERSION constant only
│               ├── chat.rb              # complete override, build_chunk (private)
│               └── client.rb            # WebSocket + auth + device identity (private)
├── test/
│   ├── test_helper.rb
│   └── providers/
│       ├── openclaw_test.rb
│       └── openclaw/
│           └── client_test.rb
├── ruby_llm-openclaw.gemspec
├── Gemfile
├── Rakefile
├── .gitignore                            # includes Gemfile.lock
└── README.md
```

### Research Insights: Simplified Structure Rationale

The original plan proposed 7 source files mirroring OpenAI's structure (Chat, Streaming, Models, Client, DeviceIdentity). Analysis reveals this is over-structured for what is essentially a WebSocket transport layer:

- **`streaming.rb` eliminated**: Contains only `build_chunk` (~10 lines), called only from `Chat`. OpenAI's `Streaming` module exists because it has 170+ lines of SSE/Faraday machinery — none of which applies here. Inlined as a private method in `Chat`.
- **`models.rb` eliminated**: Returns `[]`. `assume_models_exist?` handles everything. One-liner override on the provider class.
- **`device_identity.rb` eliminated**: Only 5 lines of meaningful logic (generate, persist, load, derive ID, sign). Only consumer is `Client`. Inlined as private methods.
- **`sync_complete`/`stream_complete` merged**: Only difference is `block.call(chunk)`. Single method with `block&.call(chunk)`.

**4 source files instead of 7.** Each file has a clear, single reason to exist.

### Phase 1: Provider Skeleton + Configuration

Register the provider and extend RubyLLM configuration.

**`lib/ruby_llm/providers/openclaw/version.rb`**
```ruby
module RubyLLM
  module Providers
    class OpenClaw
      VERSION = "0.1.0"
    end
  end
end
```

**`lib/ruby_llm-openclaw.rb`**
```ruby
# Standard library
require "digest"
require "fileutils"
require "securerandom"

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

# Configuration extension (standard pattern for provider gems)
RubyLLM::Configuration.class_eval do
  attr_accessor :openclaw_url, :openclaw_token
end

# Set defaults
RubyLLM.config.openclaw_url = "ws://localhost:18789"

# Register provider
RubyLLM::Provider.register :openclaw, RubyLLM::Providers::OpenClaw
```

### Research Insights: Configuration

- `class_eval` monkey-patching is the only option — RubyLLM has no plugin/extension mechanism for `Configuration`. All built-in providers have their keys hardcoded. This is the accepted pattern.
- The `openclaw_token` attr will be correctly filtered from `inspect`/debug output (RubyLLM filters attrs matching `/_token$/`).
- Set defaults immediately after `class_eval` per Kane gem patterns.
- `openclaw_device_key_path` dropped for v1 (YAGNI — hardcode `~/.ruby_llm/openclaw/device.key`).

**`lib/ruby_llm/providers/openclaw.rb`** — Provider class:
```ruby
module RubyLLM
  module Providers
    class OpenClaw < Provider
      include OpenClaw::Chat

      # Error hierarchy
      class Error < StandardError; end
      class ConnectionError < Error; end
      class AuthenticationError < Error; end
      class TimeoutError < Error; end

      # CRITICAL: Override initialize to skip Faraday Connection creation.
      # Base Provider#initialize creates Connection.new(self, @config) which
      # calls Faraday.new(provider.api_base) — that would point Faraday at
      # a ws:// URL and fail. We bypass HTTP entirely.
      def initialize(config)
        @config = config
        ensure_configured!
        # Intentionally skip @connection = Connection.new(self, @config)
      end

      def api_base
        @config.openclaw_url || "ws://localhost:18789"
      end

      def headers
        {}
      end

      # One-liner — no separate Models module needed
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
```

### Research Insights: Critical — Override `initialize`

The base `Provider#initialize` (line 13 of `provider.rb`) does:
```ruby
def initialize(config)
  @config = config
  ensure_configured!
  @connection = Connection.new(self, @config)
end
```

`Connection.new` creates a `Faraday.new(provider.api_base)` — pointing Faraday at `ws://localhost:18789` will either fail or create a useless connection. **Must override to skip this.**

This means `@connection` will be `nil`. Inherited methods like `sync_response` and `stream_response` won't work, but that's fine — `complete` is fully overridden.

- **Files**: `lib/ruby_llm-openclaw.rb`, `lib/ruby_llm/providers/openclaw.rb`, `lib/ruby_llm/providers/openclaw/version.rb`
- **Tests**: Provider registration, configuration validation, `assume_models_exist?` resolves any model ID

### Phase 2: Gateway WebSocket Client

The client handles WebSocket connection, Ed25519 challenge-response auth, and message exchange. Device identity logic is inlined as private methods.

**`lib/ruby_llm/providers/openclaw/client.rb`**

Core responsibilities:
- Connect to Gateway WebSocket (connect-per-request for v1)
- Handle `connect.challenge` → sign nonce → send `connect` → receive `hello-ok`
- Send `chat.send` requests (JSON `{type: "req", id, method: "chat.send", params}`)
- Receive response events (`{type: "event", event, payload}`)
- Yield streaming chunks as they arrive
- Ed25519 keypair management (generate, persist, load, sign) — private methods

### Research Insights: Connect-Per-Request (v1 Simplification)

Connection pooling was listed as a core feature but is premature for v1:
- Adds thread safety, stale detection, lifecycle management, reconnection with backoff
- For v1 (Rails app making occasional requests), connect → auth → send → receive → close is sufficient
- WebSocket handshake + Ed25519 auth is fast (~50-100ms)
- **Measure first, optimize later.** If latency is a problem, add connection reuse in v2.

### Research Insights: `Sync` Bridge Pattern (async-websocket in Rails)

`async-websocket` is fiber-based. Rails/Puma uses threads. The bridge:

```ruby
def chat_send(content, agent:, &block)
  Sync do |task|
    endpoint = Async::HTTP::Endpoint.parse(
      @url,
      alpn_protocols: Async::HTTP::Protocol::HTTP11.names
    )

    task.with_timeout(@timeout) do
      Async::WebSocket::Client.connect(endpoint) do |connection|
        authenticate(connection)
        send_chat(connection, content, agent: agent, &block)
      end
    end
  end
end
```

**Key rules:**
- `Sync` creates a temporary event loop per call — blocks the Puma thread (like a synchronous HTTP call)
- Each call gets its own isolated connection — no thread safety concerns
- **Never call ActiveRecord inside `Sync` blocks** — AR connection pool is thread-keyed, not fiber-keyed
- Force HTTP/1.1 with `alpn_protocols` (some servers don't support HTTP/2 WebSocket upgrade)
- Use `task.with_timeout` (not `Timeout.timeout` which is thread-unsafe)
- Always call `connection.flush` after writes (messages are buffered)
- `connection.read` returns `nil` when server closes — handle this

**Auth handshake** (from [OpenClaw Gateway Protocol](https://docs.openclaw.ai/gateway/protocol)):
```
1. Server → connect.challenge { nonce: "uuid" }
2. Client → connect { device: { id, publicKey, signature, signedAt, nonce }, auth: { token }, role: "operator", scopes: [...] }
3. Server → hello-ok { auth: { deviceToken }, role, scopes }
```

**Ed25519 device identity** (inlined in Client):
- Auto-generate on first use, persist to `~/.ruby_llm/openclaw/device.key`
- Derive device ID: `SHA-256(public_key)`
- Sign payloads: `v2|{deviceId}|ruby_llm|provider|operator|operator.read,operator.write|{signedAtMs}|{token}|{nonce}`

### Research Insights: Security — Key Storage

- **Set file permissions to 0700/0600** (SSH convention):
  ```ruby
  FileUtils.mkdir_p(dir, mode: 0700)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(key_bytes) }
  ```
- **Validate permissions on load** — refuse keys with group/other access:
  ```ruby
  stat = File.stat(path)
  raise SecurityError, "#{path} has insecure permissions" unless stat.mode & 0077 == 0
  ```
- File-based storage is for development only. Production should use database or secrets manager (Cora uses `encrypts` in DB).

### Research Insights: Security — Transport

- **Warn on `ws://` to non-loopback addresses:**
  ```ruby
  if url.start_with?("ws://") && !%w[localhost 127.0.0.1 ::1].include?(URI.parse(url).host)
    warn "[ruby_llm-openclaw] WARNING: Using unencrypted WebSocket to non-loopback address. Use wss:// for production."
  end
  ```
- Validate agent names: `raise ArgumentError unless agent_name.match?(/\A[a-zA-Z0-9_-]+\z/)`
- Validate token doesn't contain `|` (pipe delimiter injection in signature payload)

### Research Insights: Security — Replay Protection

- ±2 minute clock skew window is acceptable if Gateway enforces nonce uniqueness (one-time use)
- Use `Process.clock_gettime(Process::CLOCK_MONOTONIC)` for timeout tracking (not `Time.now`)
- Device tokens should have TTL — handle auth-expired responses gracefully

- **Files**: `lib/ruby_llm/providers/openclaw/client.rb`
- **Tests**: Handshake flow (mock WebSocket), device identity generation/persistence, signature correctness, file permissions, transport security warnings

### Phase 3: Chat + Streaming (Override `complete`)

This is the key integration point. Override `complete` to route through WebSocket instead of Faraday. `build_chunk` is inlined as a private method.

**`lib/ruby_llm/providers/openclaw/chat.rb`**
```ruby
module RubyLLM
  module Providers
    class OpenClaw
      module Chat
        def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, &block)
          warn_unsupported_params(tools: tools, temperature: temperature, schema: schema, thinking: thinking)
          client = Client.new(@config)
          accumulator = StreamAccumulator.new
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
          Chunk.new(
            role: :assistant,
            model_id: event_data["model"] || "openclaw",
            content: event_data["content"] || event_data["text"],
            input_tokens: event_data.dig("usage", "input_tokens"),
            output_tokens: event_data.dig("usage", "output_tokens")
          )
        end

        # Send full message history (not just last message)
        def render_messages(messages)
          messages.map { |m| { role: m.role.to_s, content: m.content.to_s } }
        end

        def warn_unsupported_params(tools:, temperature:, schema:, thinking:)
          warn "[ruby_llm-openclaw] tools: parameter ignored (OpenClaw manages tools server-side)" if tools&.any?
          warn "[ruby_llm-openclaw] temperature: parameter ignored" if temperature
          warn "[ruby_llm-openclaw] schema: parameter ignored" if schema
          warn "[ruby_llm-openclaw] thinking: parameter ignored" if thinking
        end
      end
    end
  end
end
```

### Research Insights: Critical — Send Full Message History

The original plan had `messages.last.content` which **discards all conversation history**. This breaks multi-turn conversations. Two options:

1. **Send full message array** to `chat.send` (if OpenClaw supports it) — simplest
2. **Track session key** — store OpenClaw session ID, pass on subsequent calls

Option 1 is preferred for v1. If OpenClaw maintains server-side session state, implement session tracking in v2.

### Research Insights: `StreamAccumulator.to_message(nil)`

Passing `nil` sets `raw: nil` on the resulting `Message`. The `raw` field normally holds the Faraday HTTP response object. This is acceptable — callers should not depend on `raw` for provider-agnostic code.

### Research Insights: Performance — Thread Blocking

Each `complete` call blocks a Puma thread for the entire duration of the OpenClaw agent response (potentially seconds to minutes for complex tasks). With Cora's config (2 workers × 3 threads = 6 concurrent slots):
- 6 simultaneous OpenClaw requests saturate the web tier
- For high concurrency, move to Solid Queue background jobs
- The `complete` method returns a `Message` — clean seam for `perform_later`

### Research Insights: Performance — Post-Fork Safety

Cora uses `preload_app!` in Puma. If any WebSocket state is initialized at class level before fork, it will be shared/corrupted across workers. With connect-per-request, this is not an issue — each `complete` call creates a fresh `Client`. If connection pooling is added later, use `Process.pid`-keyed storage.

- **Files**: `lib/ruby_llm/providers/openclaw/chat.rb`
- **Tests**: Sync completion, streaming with chunks, multi-turn with full message history, error mapping

### Research Insights: Error Mapping

Map WebSocket errors to RubyLLM error classes for consistent error handling:

```ruby
rescue Async::TimeoutError => e
  raise OpenClaw::TimeoutError, "Gateway timeout: #{e.message}"
rescue Async::WebSocket::ProtocolError => e
  raise OpenClaw::ConnectionError, "Protocol error: #{e.message}"
rescue Errno::ECONNREFUSED => e
  raise OpenClaw::ConnectionError, "Cannot connect to Gateway: #{e.message}"
```

## Implementation Phases (Consolidated)

### Phase 1: Skeleton + Configuration (Day 1)
- Gem scaffolding (gemspec, Gemfile, Rakefile, .gitignore, directory structure)
- Provider class with `initialize` override (skip Faraday Connection)
- Registration + configuration extension
- `assume_models_exist?` + `list_models` returning `[]`
- Version file
- Error class hierarchy
- **Success**: `RubyLLM.chat(model: "openclaw/test")` resolves to the OpenClaw provider

### Phase 2: Client + Auth (Day 2-3)
- WebSocket client using `Sync` bridge pattern (connect-per-request)
- Ed25519 device identity (generate, persist with 0600 permissions, load, sign)
- Gateway handshake (challenge → connect → hello-ok)
- Transport security warnings (ws:// to non-loopback)
- Input validation (agent name, token)
- Timeout handling via `task.with_timeout`
- **Success**: Connect to a running OpenClaw instance, complete handshake

### Phase 3: Chat + Streaming + Polish (Day 3-5)
- Override `complete` with WebSocket transport
- `chat.send` with full message history
- `build_chunk` from Gateway events (inlined in Chat)
- `StreamAccumulator` integration
- Unified sync/streaming via `block&.call`
- Error mapping to RubyLLM error classes
- Minitest specs for all components
- README
- **Success**: `chat.ask("hello")` returns a response from OpenClaw agent

## Acceptance Criteria

### Functional
- [ ] `RubyLLM.chat(model: "openclaw/agent-name").ask("hello")` returns a response
- [ ] Streaming works: `chat.ask("hello") { |chunk| ... }` yields chunks
- [ ] Multi-turn: second `.ask()` sends full conversation history
- [ ] Ed25519 handshake completes successfully against real OpenClaw instance
- [ ] Device keypair auto-generated with 0600 permissions and persisted on first connection
- [ ] Provider registered and discoverable via `RubyLLM::Provider.resolve(:openclaw)`

### Non-Functional
- [ ] Timeout handling for unresponsive Gateway (configurable, default 120s)
- [ ] Warns on `ws://` to non-loopback addresses
- [ ] No libsodium system dependency (uses `ed25519` gem)
- [ ] No ActiveRecord calls inside `Sync` blocks
- [ ] Minitest test suite passing

### Deferred to v2 (explicitly out of scope)
- [ ] Connection pooling / reuse (measure latency first)
- [ ] Graceful reconnection with exponential backoff
- [ ] OpenClaw session key tracking (server-side session state)
- [ ] Agent auto-discovery from Gateway
- [ ] Configurable scopes (currently hardcoded `operator.read,operator.write`)
- [ ] Cora integration (separate plan/PR)

## Dependencies

```ruby
# ruby_llm-openclaw.gemspec
Gem::Specification.new do |spec|
  spec.name = "ruby_llm-openclaw"
  spec.version = RubyLLM::Providers::OpenClaw::VERSION
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["*.{md,txt}", "{lib}/**/*"]
  spec.require_path = "lib"

  spec.add_dependency "ruby_llm", ">= 1.12"
  spec.add_dependency "async-websocket", "~> 0.30"
  spec.add_dependency "ed25519", "~> 1.3"

  # Dev deps in Gemfile, not gemspec
end
```

### Research Insights: Dependencies

- All three runtime dependencies are legitimate and unavoidable. `async-websocket` is actively maintained by Samuel Williams (Ruby core committer). `ed25519` is lightweight with no system dependencies.
- Do not commit `Gemfile.lock` (add to `.gitignore`) — this is a gem, not an application.
- Pin `ruby_llm >= 1.12` loosely — the internal API surface (`StreamAccumulator`, `Chunk`, `Provider#complete` signature) needs to be verified across versions.

## Risks

1. **Gateway WebSocket protocol undocumented details** — The exact `chat.send` request/response format needs to be verified against OpenClaw source code. Mitigation: read the [OpenClaw source](https://github.com/openclaw/openclaw) during implementation.

2. **Ed25519 payload format** — The `v2` signature payload format was documented but edge cases (encoding, byte order) may differ. Mitigation: test against a real OpenClaw instance early (Phase 2).

3. **async-websocket in Rails** — Fiber-based concurrency (`async` gem) may interact unexpectedly with Rails' thread model.
   - **Mitigated**: Use `Sync` bridge pattern (creates temporary event loop per call, blocks Puma thread).
   - **Rule**: Never call ActiveRecord inside `Sync` blocks.
   - **Rule**: Connection-per-request avoids thread safety issues entirely.
   - **Fallback**: `websocket-client-simple` as alternative (simpler but less maintained).

4. **Puma thread exhaustion** — Each `complete` call blocks a Puma thread for the duration of the OpenClaw response. With 6 concurrent slots (2 workers × 3 threads), 6 simultaneous requests saturate the web tier. Mitigation: move to Solid Queue for high-concurrency scenarios.

5. **Post-fork connection corruption** — Cora uses `preload_app!`. Any class-level connection state created before fork would be shared across workers. Mitigated by connect-per-request (no persistent state).

## Security Considerations

### P1 — Before first release
1. Warn or error on `ws://` to non-loopback addresses
2. Set file permissions to 0700/0600 on key directory and file; validate on load
3. Validate that token does not contain `|` (pipe delimiter injection)
4. Sanitize agent name from model ID (`/\A[a-zA-Z0-9_-]+\z/`)
5. Validate configuration completeness at connection time

### P2 — Before production use
6. Document file-based key storage is for development; production should use DB/secrets manager
7. Add TLS certificate validation for `wss://` connections
8. Implement exponential backoff on auth failures
9. Never log signature payload, token, or key material (even at debug level)

### P3 — Future hardening
10. Make scopes configurable (currently hardcoded)
11. Add `inspect` redaction for configuration objects
12. Key rotation support
13. Device token caching with TTL

## Cora Integration (Separate Plan)

The Cora integration is a **separate concern** and should be a separate plan/PR after the gem ships. Key findings from the Rails review for when that plan is created:

- **Consider reusing `ConnectedAccount`** with `provider: "openclaw"` before creating a new table (DHH review)
- If separate model: inherit from `AccountRecord` (not `ApplicationRecord`) — provides `acts_as_tenant` automatically
- Add `has_prefix_id :oclw`
- Add `belongs_to :account`
- Use `:text` columns for encrypted attributes (ciphertext is longer than plaintext)
- Add validations: `url` presence/uniqueness scoped to account, `token` presence
- Add Flipper feature flag (`openclaw: enabled: false` in `flipper_flag_defaults.yml`)
- Extract `to_llm_chat` to `OpenclawChatService < BaseService` (not on the model)
- Add YARD documentation with examples
- Create test fixtures

### Multi-Tenant Config Injection Pattern

Per-connection credentials must use `RubyLLM.context` (not the global singleton):

```ruby
# In OpenclawChatService
def run
  RubyLLM.context do |config|
    config.openclaw_url = connection.url
    config.openclaw_token = connection.token
  end.chat(model: "openclaw/#{agent_name}", provider: :openclaw)
end
```

This ensures each account's OpenClaw connection uses its own credentials without mutating global state.

### Learnings That Apply
- Follow the [Account-Scoped Feature Checklist](docs/solutions/best-practices/account-scoped-feature-checklist-20260216.md)
- Follow the [Flipper Shadow Mode Pattern](docs/solutions/best-practices/flipper-shadow-mode-gradual-rollout-20250204.md)
- [Verify lifecycle assumptions](docs/solutions/best-practices/verify-lifecycle-assumptions-before-approving-plans-20260225.md) before approving the Cora integration plan

## Sources & References

### Origin
- **Brainstorm document:** [docs/brainstorms/2026-03-11-ruby-llm-openclaw-provider-brainstorm.md](docs/brainstorms/2026-03-11-ruby-llm-openclaw-provider-brainstorm.md) — Key decisions: RubyLLM provider (not standalone), WebSocket transport, transport-only scope, `ed25519` + `async-websocket` gems, Cora model wraps gem.

### Internal References (RubyLLM Provider API)
- Provider base class: `ruby_llm/provider.rb` — `complete`, `list_models`, `assume_models_exist?`
- OpenAI provider (reference impl): `ruby_llm/providers/openai.rb` + `openai/chat.rb`, `openai/streaming.rb`, `openai/models.rb`
- DeepSeek provider (simplest reference): `ruby_llm/providers/deepseek.rb` — minimal OpenAI-derived provider
- Streaming: `ruby_llm/streaming.rb` — `stream_response`, `handle_stream`, `build_chunk` (we bypass this entirely)
- StreamAccumulator: `ruby_llm/stream_accumulator.rb` — assembles chunks into Message via `add(chunk)` + `to_message(response)`
- Connection: `ruby_llm/connection.rb` — Faraday-based (we bypass this — see `initialize` override)
- Configuration: `ruby_llm/configuration.rb` — extend with `openclaw_*` attrs via `class_eval`
- Models: `ruby_llm/models.rb` — `assume_models_exist?` creates `Model::Info.default`
- Chunk: `ruby_llm/chunk.rb` — inherits Message, no additions. Constructor takes `role:, content:, model_id:, input_tokens:, output_tokens:` etc.
- Message: `ruby_llm/message.rb` — `normalize_content` wraps strings in `Content.new`

### External References
- [OpenClaw Gateway Protocol](https://docs.openclaw.ai/gateway/protocol) — WebSocket message types, handshake flow
- [OpenClaw Auth & Device Pairing](https://deepwiki.com/openclaw/openclaw/2.2-authentication-and-device-pairing) — Ed25519 signing, payload format, pairing
- [OpenClaw Gateway Configuration](https://docs.openclaw.ai/gateway/configuration) — Agent routing, session management
- [OpenClaw Source](https://github.com/openclaw/openclaw) — Reference for protocol details
- [RubyLLM Agent DSL](https://paolino.me/rubyllm-1-12-agents/) — Agent pattern context
- [ed25519 gem](https://github.com/RubyCrypto/ed25519) — Lightweight Ed25519 signing
- [async-websocket gem](https://github.com/socketry/async-websocket) — Fiber-based WebSocket client
- [async-websocket Getting Started](https://socketry.github.io/async-websocket/guides/getting-started/index.html) — Official docs
- [async-websocket Rails Integration](https://socketry.github.io/async-websocket/guides/rails-integration/index) — Rails-specific guidance
- [Async Ruby on Rails (Thoughtbot)](https://thoughtbot.com/blog/async-ruby-on-rails) — Sync bridge pattern
- [Cora Solutions: Account-Scoped Feature Checklist](docs/solutions/best-practices/account-scoped-feature-checklist-20260216.md) — For Cora integration phase
- [Cora Solutions: Flipper Shadow Mode](docs/solutions/best-practices/flipper-shadow-mode-gradual-rollout-20250204.md) — For Cora integration phase

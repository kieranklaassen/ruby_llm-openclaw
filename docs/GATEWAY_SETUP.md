# OpenClaw Gateway Setup for ruby_llm-openclaw

Instructions for setting up an OpenClaw Gateway that a `ruby_llm-openclaw` client can connect to.

Verified against OpenClaw 2026.3.11. Full docs: https://docs.openclaw.ai

## Quick Start

```bash
# 1. Install OpenClaw
npm install -g openclaw@latest

# 2. Run the setup wizard
#    Configures LLM provider, gateway auth, and installs the daemon service.
openclaw onboard --install-daemon
```

The wizard prompts for an LLM provider API key (OpenRouter, OpenAI, Anthropic, etc.) and gateway auth settings. When prompted for gateway auth, choose **token** and set a shared secret.

After onboard completes, the gateway runs as a system service (launchd on macOS, systemd on Linux).

## Managing the Gateway Service

```bash
openclaw gateway status    # Show service status + probe reachability
openclaw gateway start     # Start the service
openclaw gateway stop      # Stop the service
openclaw gateway restart   # Restart the service
```

To run in the foreground instead (useful for debugging):

```bash
openclaw gateway run
```

## Configuring Auth via Config (Persistent)

Auth settings persist in the config file. Do not rely on ad-hoc CLI flags for production — configure via `openclaw config set`:

```bash
# Set token auth (persists across restarts)
openclaw config set gateway.auth.mode token
openclaw config set gateway.auth.token YOUR_SHARED_SECRET

# Or reference an env var instead of a plaintext token
# (set OPENCLAW_GATEWAY_TOKEN in your environment)
openclaw config set gateway.auth.mode token

# Apply changes
openclaw gateway restart
```

To verify the config:

```bash
openclaw config get gateway
# Tokens are redacted in output
```

## Non-Interactive Setup (Servers / CI)

```bash
# OpenRouter example
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --auth-choice openrouter-api-key \
  --openrouter-api-key sk-or-... \
  --gateway-auth token \
  --gateway-token YOUR_SHARED_SECRET \
  --install-daemon

# OpenAI example
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --auth-choice openai-api-key \
  --openai-api-key sk-... \
  --gateway-auth token \
  --gateway-token YOUR_SHARED_SECRET \
  --install-daemon
```

## Verify It Works

```bash
# Service status + reachability probe
openclaw gateway status

# Health check (requires running gateway)
openclaw health

# List configured agents
openclaw agents list
```

## Expose to a Remote Client

The gateway binds to **loopback only** (127.0.0.1) by default. This is intentional — never expose an unauthenticated gateway to the network.

### Option A: SSH Tunnel (simplest, no config changes)

On the **client** machine:

```bash
ssh -N -L 18789:127.0.0.1:18789 user@gateway-host
```

The client connects to `ws://localhost:18789` as if local. Gateway stays on loopback.

### Option B: Tailscale (recommended for persistent remote access)

```bash
# Expose to your tailnet only (private)
openclaw config set gateway.tailscale.mode serve
openclaw gateway restart

# Or expose publicly via Tailscale Funnel
openclaw config set gateway.tailscale.mode funnel
openclaw gateway restart
```

The client connects to `wss://your-machine.tailnet-name.ts.net:18789`.

### Option C: Bind to LAN (trusted networks only)

```bash
openclaw config set gateway.bind lan
openclaw gateway restart
```

The client connects to `ws://192.168.x.x:18789`.

**Warning:** Only use on trusted networks. Always enable token auth when binding beyond loopback. Never expose an unauthenticated gateway to any network.

## What to Share with the Client

Give the `ruby_llm-openclaw` user three things:

1. **Gateway URL** — `ws://localhost:18789` (if tunneled) or `wss://host.ts.net:18789` (if Tailscale)
2. **Token** — the shared secret you configured
3. **Agent name** — run `openclaw agents list` to see available agents (default is usually `main`)

The client configures:

```ruby
RubyLLM.configure do |config|
  config.openclaw_url   = "ws://localhost:18789"
  config.openclaw_token = "YOUR_SHARED_SECRET"
end

chat = RubyLLM.chat(model: "openclaw/main")
chat.ask("Hello!")
```

## Reference

| Command | Purpose |
|---------|---------|
| `openclaw onboard` | Interactive setup wizard |
| `openclaw gateway status` | Service status + probe |
| `openclaw gateway start` | Start the daemon |
| `openclaw gateway stop` | Stop the daemon |
| `openclaw gateway restart` | Restart after config changes |
| `openclaw gateway run` | Run in foreground (debug) |
| `openclaw health` | Health check (running gateway) |
| `openclaw agents list` | List configured agents |
| `openclaw config set <path> <value>` | Set a config value |
| `openclaw config get <path>` | Read a config value |

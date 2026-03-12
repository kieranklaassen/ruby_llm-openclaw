# OpenClaw Gateway Setup for ruby_llm-openclaw

Instructions for setting up an OpenClaw Gateway that a `ruby_llm-openclaw` client can connect to.

## Quick Start

```bash
# 1. Install OpenClaw
npm install -g openclaw@latest

# 2. Run the setup wizard with an API key
#    Pick whichever LLM provider you have credits for:
openclaw onboard --install-daemon

# 3. Start the gateway with token auth
openclaw gateway --auth token --token YOUR_SHARED_SECRET
```

The gateway is now listening on `ws://127.0.0.1:18789`.

## Non-Interactive Setup

If you want to skip the wizard (e.g. on a server):

```bash
# With OpenRouter
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --auth-choice openrouter-api-key \
  --openrouter-api-key sk-or-... \
  --gateway-auth token \
  --gateway-token YOUR_SHARED_SECRET \
  --install-daemon

# With OpenAI
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --auth-choice openai-api-key \
  --openai-api-key sk-... \
  --gateway-auth token \
  --gateway-token YOUR_SHARED_SECRET \
  --install-daemon

# With Anthropic
openclaw onboard \
  --non-interactive \
  --accept-risk \
  --auth-choice apiKey \
  --anthropic-api-key sk-ant-... \
  --gateway-auth token \
  --gateway-token YOUR_SHARED_SECRET \
  --install-daemon
```

## Verify It Works

```bash
# Check gateway status
openclaw gateway status

# Check health
openclaw gateway health

# List agents
openclaw agents list
```

## Expose to a Remote Client

The gateway binds to loopback (127.0.0.1) by default. To let a remote `ruby_llm-openclaw` client connect:

### Option A: SSH Tunnel (simplest)

On the **client** machine:

```bash
ssh -N -L 18789:127.0.0.1:18789 user@gateway-host
```

Then connect to `ws://localhost:18789` as if it were local.

### Option B: Tailscale (recommended for production)

On the **gateway** machine:

```bash
# Expose to your tailnet only
openclaw gateway --auth token --token YOUR_SHARED_SECRET --tailscale serve

# Or expose publicly via Tailscale Funnel
openclaw gateway --auth token --token YOUR_SHARED_SECRET --tailscale funnel
```

The client connects to `wss://your-machine.tailnet-name.ts.net:18789`.

### Option C: Bind to LAN

```bash
openclaw gateway --auth token --token YOUR_SHARED_SECRET --bind lan
```

The client connects to `ws://192.168.x.x:18789`. **Only use on trusted networks.**

## What to Share with the Client

Give the `ruby_llm-openclaw` user:

1. **Gateway URL** — e.g. `ws://localhost:18789` (tunneled) or `wss://host.ts.net:18789`
2. **Token** — the `YOUR_SHARED_SECRET` value
3. **Agent name** — run `openclaw agents list` to see available agents (default is `main`)

The client configures:

```ruby
RubyLLM.configure do |config|
  config.openclaw_url   = "ws://localhost:18789"
  config.openclaw_token = "YOUR_SHARED_SECRET"
end

chat = RubyLLM.chat(model: "openclaw/main")
chat.ask("Hello!")
```

# Nexus Relay

E2E-encrypted WebSocket relay for the Nexus mobile app.

```
┌──────────────┐     WSS (outbound)    ┌──────────┐     WSS (outbound)    ┌──────────────┐
│ Hermes Agent │ ←──────────────────→  │  Relay   │  ←──────────────────→  │  Nexus App   │
│ (user server)│   E2E encrypted      │ (public)  │   E2E encrypted       │ (iOS/Android) │
└──────────────┘                      └──────────┘                      └──────────────┘
```

## Components

- `relay_server.py` — public WebSocket relay, listens on `127.0.0.1:9120` by default. Routes encrypted bytes between paired endpoints. Never parses message content.
- `relay_agent.py` — runs on the agent server next to Hermes Gateway. Pairs with the app, then bridges E2E-encrypted JSON-RPC to the real Hermes Dashboard WebSocket.
- `crypto.py` — X25519 key agreement + ChaCha20-Poly1305 AEAD + HKDF-SHA256 (pynacl + cryptography).

## Quick start (local test)

```bash
# 1. Start the relay
python3 relay_server.py

# 2. Start the agent (pairing mode)
python3 relay_agent.py \
  --relay ws://127.0.0.1:9120 \
  --dashboard "ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN" \
  --pair --code 123456

# 3. Enter code 123456 in the Nexus app
```

## Production deployment

See [docs/RELAY-DEPLOYMENT.md](../docs/RELAY-DEPLOYMENT.md) at the repo root for:

- Caddy + Let's Encrypt configuration
- systemd services for relay + agent
- pairing flow details
- troubleshooting

## Dependencies

```bash
pip3 install websockets pynacl cryptography
```

iOS app dependencies: none (CryptoKit + URLSession are system frameworks).

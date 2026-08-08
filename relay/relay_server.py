#!/usr/bin/env python3
"""Nexus Relay Server — lightweight WebSocket relay for E2E encrypted mobile communication.

Routes encrypted bytes between paired Hermes Agent and Nexus App endpoints.
Does NOT parse message content. Does NOT store messages.

Deploy: run on a public server behind a TLS-terminating reverse proxy.
  Caddy: wss://relay.example.com/relay → 127.0.0.1:9120

Protocol (all messages are JSON, sent as WebSocket text frames):

  Client → Relay:
    {"type": "join", "channel": "<8-char-hex>", "role": "agent"|"app"}
    {"type": "data", "channel": "<8-char-hex>", "payload": "base64(...)"}
    {"type": "ping"}

  Relay → Client:
    {"type": "paired", "channel": "<8-char-hex>"}
    {"type": "data", "channel": "<8-char-hex>", "payload": "base64(...)"}
    {"type": "pong"}
    {"type": "error", "message": "..."}
"""

import asyncio
import json
import logging
import signal
import time
from dataclasses import dataclass, field
from typing import Optional

import websockets
from websockets.server import serve

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("relay")

RELAY_HOST = "127.0.0.1"
RELAY_PORT = 9120
HEARTBEAT_TIMEOUT = 90  # seconds without ping → drop
CLEANUP_INTERVAL = 30  # seconds between cleanup sweeps
# Security: pairing window — an unpaired channel lives at most this long,
# after which it is garbage-collected (prevents indefinite brute-force races).
PAIRING_WINDOW = 300  # 5 minutes
# Security: per-IP join attempt rate limit (anti brute-force).
JOIN_RATE_LIMIT = 5  # joins per IP per window
JOIN_RATE_WINDOW = 60  # seconds
# Security: cap total channels to bound memory — an unauthenticated attacker
# could otherwise create a Channel per random channel_id (memory DoS).
MAX_CHANNELS = 10000
# Security: per-connection message rate limit on the forward path (anti-flood).
MSG_RATE_LIMIT = 60  # messages per second per connection
MSG_RATE_BURST = 120  # burst allowance


@dataclass
class Channel:
    channel_id: str
    agent: Optional[object] = None
    app: Optional[object] = None
    created_at: float = field(default_factory=time.time)

    @property
    def both_connected(self) -> bool:
        return self.agent is not None and self.app is not None


class RelayServer:
    def __init__(self) -> None:
        self.channels: dict[str, Channel] = {}
        self._lock = asyncio.Lock()
        self._members: dict[object, str] = {}  # ws -> channel_id membership
        # Anti brute-force: (ip, channel_id) -> list of join timestamps
        self._join_attempts: dict[tuple[str, str], list[float]] = {}
        # Anti-flood: ws -> (tokens, last_refill)
        self._msg_tokens: dict[object, tuple[float, float]] = {}

    def _msg_rate_limited(self, ws) -> bool:
        """Token bucket per connection; True if the connection is flooding."""
        now = time.time()
        tokens, last = self._msg_tokens.get(ws, (MSG_RATE_BURST, now))
        tokens = min(MSG_RATE_BURST, tokens + (now - last) * MSG_RATE_LIMIT)
        if tokens < 1:
            return True
        self._msg_tokens[ws] = (tokens - 1, now)
        return False

    def _prune_msg_tokens(self, now: float) -> None:
        """Drop token buckets for closed/expired sockets (bounded memory)."""
        stale = [ws for ws in self._msg_tokens if ws not in self._members]
        for ws in stale:
            del self._msg_tokens[ws]

    def _rate_limited(self, ip: str, channel_id: str) -> bool:
        """True if this IP has exceeded the join rate limit for the channel."""
        now = time.time()
        key = (ip, channel_id)
        attempts = [t for t in self._join_attempts.get(key, []) if now - t < JOIN_RATE_WINDOW]
        self._join_attempts[key] = attempts
        if len(attempts) >= JOIN_RATE_LIMIT:
            return True
        attempts.append(now)
        return False

    def _prune_join_attempts(self, now: float) -> None:
        """Drop rate-limit entries older than the window so the dict can't
        grow unboundedly on a busy relay."""
        cutoff = now - JOIN_RATE_WINDOW
        stale = [k for k, v in self._join_attempts.items() if not v or v[-1] < cutoff]
        for k in stale:
            del self._join_attempts[k]

    def _client_ip(self, ws) -> str:
        """Real client IP for rate limiting.

        The relay sits behind Caddy on the same host, so remote_address is
        always 127.0.0.1. Trust X-Forwarded-For ONLY when the direct peer is
        the proxy (loopback); otherwise fall back to remote_address.
        """
        direct = ws.remote_address[0] if ws.remote_address else "?"
        if direct in ("127.0.0.1", "::1", "localhost"):
            try:
                xff = ws.request.headers.get("X-Forwarded-For", "")
                if xff:
                    # First entry is the original client
                    return xff.split(",")[0].strip()
            except Exception:
                pass
        return direct

    async def join(self, ws, channel_id: str, role: str) -> bool:
        async with self._lock:
            if channel_id not in self.channels and len(self.channels) >= MAX_CHANNELS:
                log.warning("channel cap reached (%d) — rejecting join %s", MAX_CHANNELS, channel_id)
                return False
            ch = self.channels.get(channel_id)
            if ch is None:
                ch = Channel(channel_id=channel_id)
                self.channels[channel_id] = ch

            if role == "agent":
                if ch.agent is not None and ch.agent.open:
                    log.warning("channel %s: agent already connected", channel_id)
                    return False
                ch.agent = ws
            elif role == "app":
                if ch.app is not None and ch.app.open:
                    log.warning("channel %s: app already connected", channel_id)
                    return False
                ch.app = ws
            else:
                return False

            # C3: register membership — only joined sockets may forward to this channel
            self._members[ws] = channel_id

            log.info("join: channel=%s role=%s both=%s", channel_id, role, ch.both_connected)

            # Explicit join ack so clients can distinguish success from
            # rejection (rate limited / slot taken / channel full) instead
            # of silently assuming success.
            try:
                await ws.send(json.dumps({"type": "joined", "channel": channel_id}))
            except Exception:
                pass

            if ch.both_connected:
                await self._notify_paired(ch)
            return True

    async def _notify_paired(self, ch: Channel) -> None:
        msg = json.dumps({"type": "paired", "channel": ch.channel_id})
        tasks = []
        if ch.agent and ch.agent.open:
            tasks.append(ch.agent.send(msg))
        if ch.app and ch.app.open:
            tasks.append(ch.app.send(msg))
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        log.info("paired: channel=%s", ch.channel_id)

    async def forward(self, ws, channel_id: str, payload: str) -> None:
        # C3: reject data from sockets that never joined this channel
        if self._members.get(ws) != channel_id:
            await ws.send(json.dumps({"type": "error", "message": "not joined"}))
            return
        # Anti-flood: per-connection token bucket — drop (and disconnect)
        # connections that exceed the forward rate.
        if self._msg_rate_limited(ws):
            log.warning("flood: closing connection (rate limit)")
            await ws.close(code=1008, reason="rate limited")
            return
        ch = self.channels.get(channel_id)
        if ch is None:
            await ws.send(json.dumps({"type": "error", "message": "unknown channel"}))
            return

        target = ch.app if ws is ch.agent else ch.agent
        if target is None or not target.open:
            await ws.send(json.dumps({"type": "error", "message": "peer not connected"}))
            return

        msg = json.dumps({"type": "data", "channel": channel_id, "payload": payload})
        try:
            await target.send(msg)
        except Exception:
            log.warning("forward failed: channel=%s", channel_id)

    async def remove(self, ws, channel_id: str) -> None:
        async with self._lock:
            self._msg_tokens.pop(ws, None)
            ch = self.channels.get(channel_id)
            if ch is None:
                return
            peer = None
            if ch.agent is ws:
                ch.agent = None
                peer = ch.app
            if ch.app is ws:
                ch.app = None
                peer = ch.agent
            # Close the peer's connection so it reconnects and rejoins.
            # Without this, a stale half-open channel blocks re-pairing.
            if peer is not None and peer.open:
                log.info("closing peer connection for channel %s", channel_id)
                t = asyncio.create_task(peer.close(code=1000, reason="peer disconnected"))
                t.add_done_callback(lambda fut: fut.exception() if not fut.cancelled() else None)
            if ch.agent is None and ch.app is None:
                del self.channels[channel_id]
                log.info("channel %s removed (empty)", channel_id)
            # C3: clear membership for this socket
            self._members.pop(ws, None)

    async def cleanup(self) -> None:
        while True:
            await asyncio.sleep(CLEANUP_INTERVAL)
            now = time.time()
            self._prune_join_attempts(now)
            self._prune_msg_tokens(now)
            stale = []
            async with self._lock:
                for cid, ch in list(self.channels.items()):
                    age = now - ch.created_at
                    if not ch.both_connected:
                        # Security: pairing window — unpaired channels expire
                        # so a channel can't be squatted/brute-forced forever.
                        if age > PAIRING_WINDOW:
                            stale.append(cid)
                    elif age > 86400:
                        stale.append(cid)
                for cid in stale:
                    ch = self.channels.get(cid)
                    # Close any lingering sockets so clients reconnect & rejoin
                    for sock in (ch.agent, ch.app):
                        if sock is not None and sock.open:
                            t = asyncio.create_task(sock.close(code=1000, reason="channel expired"))
                            t.add_done_callback(lambda fut: fut.exception() if not fut.cancelled() else None)
                        self._members.pop(sock, None)
                    del self.channels[cid]
                    log.info("channel %s cleaned up (age=%.0fs)", cid, age)

    async def handle(self, ws) -> None:
        peer = ws.remote_address if hasattr(ws, "remote_address") else "?"
        joined_channel: Optional[str] = None

        log.info("connect from %s", peer)
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await ws.send(json.dumps({"type": "error", "message": "invalid json"}))
                    continue

                mtype = msg.get("type")
                if mtype == "ping":
                    await ws.send(json.dumps({"type": "pong"}))
                elif mtype == "join":
                    channel_id = msg.get("channel", "")
                    role = msg.get("role", "")
                    if not channel_id or role not in ("agent", "app"):
                        await ws.send(json.dumps({"type": "error", "message": "bad join"}))
                        continue
                    # Security: per-IP rate limit on join attempts (anti brute-force)
                    ip = self._client_ip(ws)
                    if self._rate_limited(ip, channel_id):
                        log.warning("rate limited: %s join %s", ip, channel_id)
                        await ws.send(json.dumps({"type": "error", "message": "rate limited"}))
                        continue
                    ok = await self.join(ws, channel_id, role)
                    if ok:
                        joined_channel = channel_id
                    else:
                        await ws.send(json.dumps({"type": "error", "message": "join failed"}))
                elif mtype == "data":
                    channel_id = msg.get("channel", "")
                    payload = msg.get("payload", "")
                    if not channel_id or not payload:
                        continue
                    await self.forward(ws, channel_id, payload)
                else:
                    await ws.send(json.dumps({"type": "error", "message": f"unknown type: {mtype}"}))

        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as exc:
            log.exception("handler error: %s", exc)
        finally:
            if joined_channel:
                await self.remove(ws, joined_channel)
            else:
                # Never joined a channel (or joined multiple) — still clear membership
                self._members.pop(ws, None)
            log.info("disconnect from %s channel=%s", peer, joined_channel)


async def main() -> None:
    server = RelayServer()
    cleanup_task = asyncio.create_task(server.cleanup())

    stop_event = asyncio.Event()

    def _stop(*_):
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_event_loop().add_signal_handler(sig, _stop)
        except NotImplementedError:
            signal.signal(sig, _stop)

    log.info("relay listening on %s:%d", RELAY_HOST, RELAY_PORT)

    async with serve(server.handle, RELAY_HOST, RELAY_PORT):
        await stop_event.wait()
        cleanup_task.cancel()
        await asyncio.gather(cleanup_task, return_exceptions=True)
        log.info("relay shutting down")


if __name__ == "__main__":
    asyncio.run(main())
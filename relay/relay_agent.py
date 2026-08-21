#!/usr/bin/env python3
"""Hermes Agent mobile relay client — connects to Relay, bridges JSON-RPC over E2E.

Run: python3 relay_agent.py --relay wss://relay.example.com/relay --pair

Once paired, starts automatically with: python3 relay_agent.py --relay wss://relay.example.com/relay
"""

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import secrets
import sys
from pathlib import Path

import websockets

# Add crypto module
sys.path.insert(0, str(Path(__file__).parent))
from crypto import (
    KeyPair, compute_shared_secret, derive_enc_key,
    encrypt_jsonrpc, decrypt_jsonrpc, decrypt_with_seq, channel_id_from_pairing_code,
    save_enc_key, load_enc_key, save_peer_pubkey, load_peer_pubkey,
    save_sequence, load_sequence, KeyPair as KP,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("mobile")

MOBILE_DIR = Path.home() / ".hermes" / "mobile"


class MobileRelayClient:
    def __init__(self, relay_url: str, dashboard_url: str = ""):
        self.relay_url = relay_url
        self.dashboard_url = dashboard_url
        self.ws = None
        self.dash_ws = None
        self._dash_pending: dict[str, asyncio.Future] = {}
        self._dash_lock = asyncio.Lock()
        self.channel_id: str | None = None
        self.enc_key: bytes | None = None
        self.send_key: bytes | None = None
        self.recv_key: bytes | None = None
        self.send_seq = 0
        self.recv_seq = 0
        self.keypair: KeyPair | None = None
        self.peer_pubkey: bytes | None = None

    @property
    def is_paired(self) -> bool:
        return (MOBILE_DIR / "enc_key").exists() and (MOBILE_DIR / "paired_pubkey").exists()

    def load_state(self):
        if self.is_paired:
            shared = load_enc_key(MOBILE_DIR / "enc_key")
            self.enc_key = shared
            # Direction-separated keys: agent sends with agent_to_app, receives with app_to_agent
            self.send_key = derive_enc_key(shared, "agent_to_app")
            self.recv_key = derive_enc_key(shared, "app_to_agent")
            self.peer_pubkey = load_peer_pubkey(MOBILE_DIR / "paired_pubkey")
            self.keypair = KeyPair.load(MOBILE_DIR / "keypair")
            # Channel ID stored alongside enc_key
            channel_file = MOBILE_DIR / "channel_id"
            if channel_file.exists():
                self.channel_id = channel_file.read_text().strip()
            self.send_seq = load_sequence(MOBILE_DIR / "send_seq")
            self.recv_seq = load_sequence(MOBILE_DIR / "recv_seq")
            log.info("loaded pairing state: channel=%s", self.channel_id)

    async def connect(self):
        log.info("connecting to relay: %s", self.relay_url)
        self.ws = await websockets.connect(self.relay_url, ping_interval=30, ping_timeout=90)
        log.info("connected to relay")

        if self.channel_id:
            await self._join(self.channel_id, "agent")
            log.info("joined channel: %s", self.channel_id)

    async def _join(self, channel_id: str, role: str):
        msg = {"type": "join", "channel": channel_id, "role": role}
        await self.ws.send(json.dumps(msg))
        # Wait for the join ack — a failed join (rate limited / slot taken /
        # channel expired) would otherwise be silently treated as success and
        # every data send would fail with "not joined".
        try:
            reply = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=5))
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed) as e:
            raise ConnectionError(f"join {channel_id} timed out: {e}") from e
        if reply.get("type") == "error":
            raise ConnectionError(f"join {channel_id} rejected: {reply.get('message')}")

    async def _send_data(self, payload: str):
        if not self.channel_id:
            return
        msg = {"type": "data", "channel": self.channel_id, "payload": payload}
        await self.ws.send(json.dumps(msg))

    async def pair_and_run(self, code: str):
        """Pair with a mobile app, then immediately enter communication loop."""
        # Fresh pairing: wipe any previous pairing state so old keys/counters
        # cannot mix with the new keypair (would cause decrypt failures).
        for f in ("keypair", "enc_key", "paired_pubkey", "channel_id", "send_seq", "recv_seq"):
            p = MOBILE_DIR / f
            if p.exists():
                p.unlink()
        # Reset in-memory state too — stale keys from a previous run would
        # otherwise be used to decrypt the app's pairing messages.
        self.enc_key = None
        self.send_key = None
        self.recv_key = None
        self.peer_pubkey = None
        self.send_seq = 0
        self.recv_seq = 0
        self.keypair = KeyPair()
        self.keypair.save(MOBILE_DIR / "keypair")
        self.channel_id = channel_id_from_pairing_code(code)

        await self.connect()
        # connect() already joins when channel_id is set

        log.info("pairing code: %s**** — waiting for app...", code[:2])
        log.info("channel: %s", self.channel_id)

        # Wait for app to join — retry if the relay drops us (e.g. the
        # 5-minute pairing window expires and the channel is cleaned up).
        while True:
            try:
                msg = json.loads(await self.ws.recv())
                if msg.get("type") == "paired":
                    log.info("app connected, exchanging keys...")
                    break
            except websockets.exceptions.ConnectionClosed as e:
                log.warning("connection closed while waiting (%s) — rejoining in 3s", e)
                await asyncio.sleep(3)
                try:
                    await self.connect()
                except Exception as ce:
                    log.warning("rejoin failed: %s", ce)

        # Send our public key
        await self._send_data(base64.b64encode(self.keypair.public_bytes).decode())

        # Receive app's public key
        while True:
            try:
                msg = json.loads(await self.ws.recv())
                if msg.get("type") == "data":
                    self.peer_pubkey = base64.b64decode(msg["payload"])
                    break
            except websockets.exceptions.ConnectionClosed as e:
                log.warning("connection closed while exchanging (%s) — rejoining in 3s", e)
                await asyncio.sleep(3)
                try:
                    await self.connect()
                except Exception as ce:
                    log.warning("rejoin failed: %s", ce)

        # Compute shared secret and derive direction-separated keys.
        # PSK-blind with the pairing code so the key agreement is bound to
        # knowledge of the code (defeats MITM by relay/on-path attackers).
        psk = code.encode("utf-8")
        shared = compute_shared_secret(self.keypair.private_bytes, self.peer_pubkey, psk=psk)
        self.enc_key = shared
        self.send_key = derive_enc_key(shared, "agent_to_app")
        self.recv_key = derive_enc_key(shared, "app_to_agent")

        # Save state
        MOBILE_DIR.mkdir(parents=True, exist_ok=True)
        save_enc_key(MOBILE_DIR / "enc_key", self.enc_key)
        save_peer_pubkey(MOBILE_DIR / "paired_pubkey", self.peer_pubkey)
        (MOBILE_DIR / "channel_id").write_text(self.channel_id)
        save_sequence(MOBILE_DIR / "send_seq", 0)
        save_sequence(MOBILE_DIR / "recv_seq", 0)

        # Send encrypted confirmation
        confirm = {"jsonrpc": "2.0", "method": "event", "params": {"type": "paired"}}
        wire = encrypt_jsonrpc(confirm, self.send_key, self.send_seq, self.channel_id)
        await self._send_data(wire)
        self.send_seq += 1
        save_sequence(MOBILE_DIR / "send_seq", self.send_seq)

        log.info("pairing complete! entering communication mode...")

        # Keep the connection alive indefinitely. The relay closes our
        # connection when the peer drops, so any loop exit means reconnect.
        while True:
            try:
                await self._message_loop()
                # Message loop ended without exception (connection closed cleanly)
                log.warning("message loop ended, reconnecting in 3s...")
            except websockets.exceptions.ConnectionClosed as e:
                log.warning("connection closed (%s), reconnecting in 3s...", e)
            except Exception as e:
                log.exception("error in message loop: %s", e)
            await asyncio.sleep(3)
            try:
                await self.connect()
                log.info("reconnected to relay, joined channel %s", self.channel_id)
                # New connection = new session: reset BOTH counters so nonce
                # sequences align with the peer (which also restarts at 0).
                self.recv_seq = 0
                self.send_seq = 0
                save_sequence(MOBILE_DIR / "recv_seq", 0)
                save_sequence(MOBILE_DIR / "send_seq", 0)
                # Re-key on reconnect — never reuse the previous session's
                # key+nonce space (ChaCha20 keystream reuse protection).
                # pair_and_run did NOT wait for 'paired' here — _rekey does.
                await self._rekey(wait_paired=True)
            except Exception as e:
                log.warning("reconnect failed: %s", e)

    async def _rekey(self, wait_paired: bool = False) -> None:
        """Re-derive session keys on a new connection.

        Generates a fresh ephemeral X25519 keypair, exchanges public keys
        with the app (plaintext, like the initial pairing handshake), and
        derives NEW directional keys. Guarantees a reconnect never reuses
        the previous session's key+nonce space (ChaCha20 keystream reuse).

        `wait_paired`: set True when the caller did NOT already wait for the
        'paired' event (pair_and_run's reconnect path) — the relay only sends
        'paired' once both endpoints are in the channel, so rekeying before
        the app joins would block forever.
        """
        if wait_paired:
            while True:
                try:
                    msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=15))
                except asyncio.TimeoutError:
                    raise ConnectionError("rekey: no paired event (app absent)") from None
                except websockets.exceptions.ConnectionClosed as e:
                    log.warning("rekey: connection closed (%s)", e)
                    raise
                if msg.get("type") == "paired":
                    break

        self.keypair = KeyPair()
        # Send our fresh public key (plaintext — same as pairing handshake)
        await self._send_data(base64.b64encode(self.keypair.public_bytes).decode())
        log.info("rekey: sent fresh public key, waiting for app's...")

        # Receive the app's fresh public key — bounded wait so a stuck peer
        # can't block the reconnect loop forever.
        while True:
            try:
                msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=10))
            except asyncio.TimeoutError:
                raise ConnectionError("rekey: timed out waiting for app public key") from None
            except websockets.exceptions.ConnectionClosed as e:
                log.warning("rekey: connection closed (%s)", e)
                raise
            if msg.get("type") != "data":
                continue
            try:
                pub = base64.b64decode(msg["payload"])
                if len(pub) == 32:
                    self.peer_pubkey = pub
                    break
            except Exception:
                continue
            # Encrypted data (old key) during rekey → ignore, keep waiting

        shared = compute_shared_secret(self.keypair.private_bytes, self.peer_pubkey)
        self.enc_key = shared
        self.send_key = derive_enc_key(shared, "agent_to_app")
        self.recv_key = derive_enc_key(shared, "app_to_agent")
        self.send_seq = 0
        self.recv_seq = 0
        save_enc_key(MOBILE_DIR / "enc_key", self.enc_key)
        save_peer_pubkey(MOBILE_DIR / "paired_pubkey", self.peer_pubkey)
        save_sequence(MOBILE_DIR / "send_seq", 0)
        save_sequence(MOBILE_DIR / "recv_seq", 0)
        log.info("rekey complete: fresh session keys derived")

    async def _message_loop(self):
        """Process encrypted messages from the current WebSocket connection."""
        async for raw in self.ws:
            msg = json.loads(raw)
            if msg.get("type") != "data":
                if msg.get("type") == "ping":
                    await self.ws.send(json.dumps({"type": "pong"}))
                continue

            payload = msg.get("payload", "")
            try:
                seq, plaintext = decrypt_with_seq(payload, self.recv_key)
            except Exception:
                log.warning("decrypt failed")
                continue

            # H4: reject replays — incoming seq must equal expected recv_seq
            if seq != self.recv_seq:
                log.warning("replay/mismatch: got seq=%d expected=%d — dropping", seq, self.recv_seq)
                continue

            self.recv_seq += 1
            save_sequence(MOBILE_DIR / "recv_seq", self.recv_seq)

            try:
                rpc = json.loads(plaintext)
            except json.JSONDecodeError:
                log.warning("bad json after decrypt")
                continue

            log.info("rpc: method=%s id=%s", rpc.get("method"), rpc.get("id"))

            response = await self.handle_rpc(rpc)

            if response:
                wire = encrypt_jsonrpc(response, self.send_key, self.send_seq, self.channel_id)
                log.info("rpc response: id=%s len=%d", response.get("id"), len(wire))
                await self._send_data(wire)
                self.send_seq += 1
                save_sequence(MOBILE_DIR / "send_seq", self.send_seq)

    async def run(self):
        """Main loop: connect to Relay, wait for app, process encrypted messages."""
        if not self.is_paired:
            log.error("not paired — run with --pair first")
            return

        self.load_state()

        backoff = 3  # seconds; doubles up to 60 on repeated failures
        while True:
            try:
                await self.connect()

                # Wait for app to join
                paired = False
                while not paired:
                    msg = json.loads(await self.ws.recv())
                    if msg.get("type") == "paired":
                        paired = True
                        log.info("app connected")

                # New connection = new session: reset receive counter so the
                # peer's fresh sequence numbers (starting at 0) are accepted.
                self.recv_seq = 0
                self.send_seq = 0
                save_sequence(MOBILE_DIR / "recv_seq", 0)
                save_sequence(MOBILE_DIR / "send_seq", 0)
                backoff = 3  # connection established — reset backoff

                # Re-key on reconnect — never reuse the previous session's
                # key+nonce space (ChaCha20 keystream reuse protection).
                # run() already waited for 'paired' above.
                await self._rekey()

                await self._message_loop()

            except websockets.exceptions.ConnectionClosed:
                log.warning("connection closed, reconnecting in %ds...", backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)
                # New connection = new session: reset both counters
                self.recv_seq = 0
                self.send_seq = 0
                save_sequence(MOBILE_DIR / "recv_seq", 0)
                save_sequence(MOBILE_DIR / "send_seq", 0)
            except Exception as e:
                log.exception("error: %s", e)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)
                self.recv_seq = 0
                self.send_seq = 0
                save_sequence(MOBILE_DIR / "recv_seq", 0)
                save_sequence(MOBILE_DIR / "send_seq", 0)

    async def handle_rpc(self, rpc: dict) -> dict | None:
        """Bridge JSON-RPC to Hermes Dashboard via WebSocket."""
        method = rpc.get("method", "")
        rid = rpc.get("id")
        params = rpc.get("params", {})

        if method == "ping":
            return {"jsonrpc": "2.0", "id": rid, "result": {"pong": True}}

        if method == "event" and params.get("type") == "paired":
            return None

        # H3: method allowlist — a phone is a low-trust device. Block methods
        # that expose secrets or grant control beyond chat/approvals.
        # profiles.list/create/configure: v2 bot roster is server truth — the
        # phone may spawn/rename bot profiles, mirroring the desktop web UI's
        # profiles page. profiles.describe/set_asset/get_asset deliberately
        # omitted (no UI consumer / avatar upload deferred). Delete has no RPC
        # (REST/CLI only) — app uses a local tombstone.
        allowed = {
            "session.list", "session.resume", "session.history", "session.status",
            "session.create", "session.interrupt", "prompt.submit", "approval.respond",
            "approval.list", "cron.manage", "agents.list", "model.options",
            "tools.list", "toolsets.list",
            "profiles.list", "profiles.create", "profiles.configure",
        }
        if method not in allowed:
            log.warning("blocked method: %s", method)
            return {"jsonrpc": "2.0", "id": rid, "result": {"error": f"method not allowed: {method}"}}

        return await self.dashboard_call(method, params, rid)

    async def dashboard_call(self, method: str, params: dict, rid) -> dict:
        """Forward a JSON-RPC call to the real Hermes Dashboard.

        H5: a single background reader dispatches responses by id to pending
        futures — concurrent calls never steal each other's responses.
        """
        if self.dash_ws is None:
            try:
                self.dash_ws = await websockets.connect(
                    self.dashboard_url, ping_interval=30, ping_timeout=90
                )
                # Consume gateway.ready
                await asyncio.wait_for(self.dash_ws.recv(), timeout=5)
                # Never log the full URL — it embeds the access token.
                safe = self.dashboard_url.split("?")[0] + "?token=[REDACTED]"
                log.info("connected to dashboard: %s", safe)
                asyncio.create_task(self._dash_reader())
            except Exception as e:
                log.warning("dashboard connect failed: %s", e)
                self.dash_ws = None
                return {"jsonrpc": "2.0", "id": rid,
                        "result": {"error": f"dashboard unavailable: {e}"}}

        dash_id = f"relay-{rid}"
        fut = asyncio.get_event_loop().create_future()
        async with self._dash_lock:
            self._dash_pending[dash_id] = fut

        req = {"jsonrpc": "2.0", "id": dash_id, "method": method, "params": params}
        try:
            await self.dash_ws.send(json.dumps(req))
        except Exception as e:
            self._dash_pending.pop(dash_id, None)
            return {"jsonrpc": "2.0", "id": rid,
                    "result": {"error": f"dashboard send failed: {e}"}}

        try:
            result = await asyncio.wait_for(fut, timeout=30)
            return {"jsonrpc": "2.0", "id": rid, "result": result}
        except asyncio.TimeoutError:
            self._dash_pending.pop(dash_id, None)
            return {"jsonrpc": "2.0", "id": rid,
                    "result": {"error": "dashboard timeout"}}

    async def _dash_reader(self) -> None:
        """Single reader: match responses by id, push events aside."""
        try:
            async for raw in self.dash_ws:
                msg = json.loads(raw)
                mid = msg.get("id")
                if mid is not None and mid in self._dash_pending:
                    fut = self._dash_pending.pop(mid)
                    if not fut.done():
                        fut.set_result(msg.get("result", {}))
                # Events (no id) are intentionally ignored here; the mobile
                # client polls, so live pushes are out of scope for now.
        except Exception as e:
            log.warning("dashboard reader ended: %s", e)
            # Fail all pending on disconnect so callers don't hang
            for fut in self._dash_pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("dashboard disconnected"))
            self._dash_pending.clear()
            # CRITICAL: clear dash_ws so the next dashboard_call lazily
            # reconnects instead of reusing a dead socket forever.
            async with self._dash_lock:
                if self.dash_ws is not None:
                    try:
                        await self.dash_ws.close()
                    except Exception:
                        pass
                    self.dash_ws = None


def main():
    parser = argparse.ArgumentParser(description="Hermes mobile relay client")
    parser.add_argument("--relay", required=True, help="Relay URL, e.g. wss://relay.example.com/relay")
    # H2: prefer env vars over CLI args so tokens never appear in ps/history/systemd
    default_dash = os.environ.get("HERMES_DASHBOARD_WS", "")
    parser.add_argument("--dashboard", default=default_dash, help="Hermes Dashboard WS URL (or set HERMES_DASHBOARD_WS)")
    parser.add_argument("--pair", action="store_true", help="Generate pairing code")
    parser.add_argument("--code", default=None, help="Use specific pairing code (8-char alphanumeric, e.g. K7mP2xQ9)")
    parser.add_argument("--daemon", action="store_true", help="Detach into the background (nexus-agent internal)")
    parser.add_argument("--log-file", default=None, help="Write logs to this file (nexus-agent internal)")
    parser.add_argument("--pidfile", default=None, help="Write our pid here after daemonizing (nexus-agent internal)")
    args = parser.parse_args()

    if args.daemon:
        if args.pair:
            print("ERROR: --pair and --daemon are mutually exclusive", file=sys.stderr)
            sys.exit(2)
        _daemonize(args)

    client = MobileRelayClient(args.relay, args.dashboard)

    if args.pair:
        # Security: 8-char alphanumeric code (32^8 ≈ 10^12 space) — a 6-digit
        # numeric code (10^6) is brute-forceable: an attacker can precompute
        # channel ids and race the real app to join the channel (MITM).
        if args.code:
            code = args.code.strip().upper()
            if not (8 <= len(code) <= 12) or not code.replace("-", "").isalnum():
                log.error("pairing code must be 8-12 alphanumeric chars (e.g. K7M2P9QX)")
                return
        else:
            alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no I/O/1/0 ambiguity
            code = "".join(secrets.choice(alphabet) for _ in range(8))
        print(f"\n  Pairing code: {code}\n  Enter this in Nexus app (Add Server).\n")
        asyncio.run(client.pair_and_run(code))
    else:
        asyncio.run(client.run())


def _daemonize(args) -> None:
    """Detach into the background (double-fork) when --daemon is passed.

    Redirects stdin/stdout/stderr to the log file; the parent exits
    immediately so the calling shell/nexus-agent sees a clean return.
    Writes our pid to --pidfile (after the second fork) so supervisors can
    verify identity instead of trusting a stale pidfile.
    """
    log_path = args.log_file or str(Path.home() / ".hermes" / "mobile-agent.log")
    log_dir = os.path.dirname(log_path)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    # First fork
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    # Second fork (prevents re-acquiring a controlling terminal)
    if os.fork() > 0:
        os._exit(0)

    if args.pidfile:
        Path(args.pidfile).write_text(str(os.getpid()))

    sys.stdin = open(os.devnull)
    sys.stdout.flush()
    sys.stderr.flush()
    # Rotating log: 5MB x 3 backups — the daemon runs for weeks; a single
    # unbounded append-only file would grow without limit.
    from logging.handlers import RotatingFileHandler
    fh = RotatingFileHandler(log_path, maxBytes=5 * 1024 * 1024, backupCount=3)
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    log.handlers = [fh]
    log_file = open(log_path, "a")
    sys.stdout = log_file
    sys.stderr = log_file
    log.info("daemonized, log: %s (5MB x 3 rotating)", log_path)


if __name__ == "__main__":
    main()
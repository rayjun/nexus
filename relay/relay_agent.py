#!/usr/bin/env python3
"""Hermes Agent mobile relay client — connects to Relay, bridges JSON-RPC over E2E.

Run: python3 relay_agent.py --relay wss://erc8004list.xyz/relay --pair

Once paired, starts automatically with: python3 relay_agent.py --relay wss://erc8004list.xyz/relay
"""

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import sys
from pathlib import Path

import websockets

# Add crypto module
sys.path.insert(0, str(Path(__file__).parent))
from crypto import (
    KeyPair, compute_shared_secret, derive_enc_key,
    encrypt_jsonrpc, decrypt_jsonrpc, channel_id_from_pairing_code,
    save_enc_key, load_enc_key, save_peer_pubkey, load_peer_pubkey,
    save_sequence, load_sequence, KeyPair as KP,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("mobile")

MOBILE_DIR = Path.home() / ".hermes" / "mobile"


class MobileRelayClient:
    def __init__(self, relay_url: str):
        self.relay_url = relay_url
        self.ws = None
        self.channel_id: str | None = None
        self.enc_key: bytes | None = None
        self.send_seq = 0
        self.recv_seq = 0
        self.keypair: KeyPair | None = None
        self.peer_pubkey: bytes | None = None

    @property
    def is_paired(self) -> bool:
        return (MOBILE_DIR / "enc_key").exists() and (MOBILE_DIR / "paired_pubkey").exists()

    def load_state(self):
        if self.is_paired:
            self.enc_key = load_enc_key(MOBILE_DIR / "enc_key")
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

    async def _send_data(self, payload: str):
        if not self.channel_id:
            return
        msg = {"type": "data", "channel": self.channel_id, "payload": payload}
        await self.ws.send(json.dumps(msg))

    async def pair_and_run(self, code: str):
        """Pair with a mobile app, then immediately enter communication loop."""
        self.keypair = KeyPair()
        self.keypair.save(MOBILE_DIR / "keypair")
        self.channel_id = channel_id_from_pairing_code(code)

        await self.connect()
        # connect() already joins when channel_id is set

        log.info("pairing code: %s — waiting for app...", code)
        log.info("channel: %s", self.channel_id)

        # Wait for app to join
        while True:
            msg = json.loads(await self.ws.recv())
            if msg.get("type") == "paired":
                log.info("app connected, exchanging keys...")
                break

        # Send our public key
        await self._send_data(base64.b64encode(self.keypair.public_bytes).decode())

        # Receive app's public key
        while True:
            msg = json.loads(await self.ws.recv())
            if msg.get("type") == "data":
                self.peer_pubkey = base64.b64decode(msg["payload"])
                break

        # Compute shared secret and derive key
        shared = compute_shared_secret(self.keypair.private_bytes, self.peer_pubkey)
        self.enc_key = derive_enc_key(shared)

        # Save state
        MOBILE_DIR.mkdir(parents=True, exist_ok=True)
        save_enc_key(MOBILE_DIR / "enc_key", self.enc_key)
        save_peer_pubkey(MOBILE_DIR / "paired_pubkey", self.peer_pubkey)
        (MOBILE_DIR / "channel_id").write_text(self.channel_id)
        save_sequence(MOBILE_DIR / "send_seq", 0)
        save_sequence(MOBILE_DIR / "recv_seq", 0)

        # Send encrypted confirmation
        confirm = {"jsonrpc": "2.0", "method": "event", "params": {"type": "paired"}}
        wire = encrypt_jsonrpc(confirm, self.enc_key, self.send_seq, self.channel_id)
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
            except Exception as e:
                log.warning("reconnect failed: %s", e)

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
                rpc = decrypt_jsonrpc(payload, self.enc_key)
            except Exception:
                log.warning("decrypt failed")
                continue

            self.recv_seq += 1
            save_sequence(MOBILE_DIR / "recv_seq", self.recv_seq)

            log.info("rpc: method=%s id=%s", rpc.get("method"), rpc.get("id"))

            response = await self.handle_rpc(rpc)

            if response:
                wire = encrypt_jsonrpc(response, self.enc_key, self.send_seq, self.channel_id)
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

                await self._message_loop()

            except websockets.exceptions.ConnectionClosed:
                log.warning("connection closed, reconnecting in 3s...")
                await asyncio.sleep(3)
            except Exception as e:
                log.exception("error: %s", e)
                await asyncio.sleep(3)

    async def handle_rpc(self, rpc: dict) -> dict | None:
        """Bridge JSON-RPC to Hermes dispatch(). Placeholder — replace with real dispatch."""
        method = rpc.get("method", "")
        rid = rpc.get("id")
        params = rpc.get("params", {})

        if method == "ping":
            return {"jsonrpc": "2.0", "id": rid, "result": {"pong": True}}

        if method == "event" and params.get("type") == "paired":
            return None

        if method == "session.list":
            return {"jsonrpc": "2.0", "id": rid, "result": {"sessions": [
                {"id": "s1", "title": "Test Session 1", "preview": "Hello world", "message_count": 5, "started_at": 1754000000.0},
                {"id": "s2", "title": "Test Session 2", "preview": "Write a script", "message_count": 3, "started_at": 1754000100.0},
            ]}}

        if method == "cron.manage":
            return {"jsonrpc": "2.0", "id": rid, "result": {"jobs": [
                {"job_id": "j1", "name": "Daily Report", "schedule": "0 9 * * *", "enabled": True},
            ]}}

        if method == "session.resume":
            return {"jsonrpc": "2.0", "id": rid, "result": {
                "session_id": params.get("session_id", "s1"),
                "messages": [
                    {"role": "user", "content": "Hello", "id": "m1"},
                    {"role": "assistant", "content": "Hi there!", "id": "m2"},
                ],
            }}

        if method == "session.history":
            return {"jsonrpc": "2.0", "id": rid, "result": {
                "messages": [
                    {"role": "user", "content": "Hello", "id": "m1"},
                    {"role": "assistant", "content": "Hi there!", "id": "m2"},
                ],
            }}

        return {"jsonrpc": "2.0", "id": rid, "result": {}}


def main():
    parser = argparse.ArgumentParser(description="Hermes mobile relay client")
    parser.add_argument("--relay", default="wss://erc8004list.xyz/relay", help="Relay URL")
    parser.add_argument("--pair", action="store_true", help="Generate pairing code")
    parser.add_argument("--code", default=None, help="Use specific pairing code")
    args = parser.parse_args()

    client = MobileRelayClient(args.relay)

    if args.pair:
        code = args.code or str(hash(os.urandom(4)) % 1000000).zfill(6)
        print(f"\n  Pairing code: {code}\n  Enter this in Nexus app.\n")
        asyncio.run(client.pair_and_run(code))
    else:
        asyncio.run(client.run())


if __name__ == "__main__":
    main()
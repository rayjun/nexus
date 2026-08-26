/**
 * End-to-end test: TS SDK as the "app" against the real relay + relay_agent.
 *
 * Flow (mirrors iOS PairingView + ChatView):
 *   1. connect ws://127.0.0.1:9120/relay, join channel (role=app)
 *   2. exchange public keys (agent sends first, app replies)
 *   3. PSK-blend ECDH → direction-split keys (app_to_agent sends)
 *   4. read agent's encrypted "paired" event (proves agent→app decrypt)
 *   5. profiles.list → session.create → prompt.submit
 *   6. observe forwarded message.* stream events (v2.1.5)
 */
import {
  KeyPair, computeSharedSecret, deriveEncKey,
  encryptJsonRpc, decryptWithSeq, channelIdFromPairingCode,
} from "../src/crypto.ts";

const RELAY_URL = process.env.RELAY_URL ?? "ws://127.0.0.1:9120/relay";
const CODE = process.env.PAIR_CODE ?? "E2EPASS8-FRESH-16CH";
const channel = channelIdFromPairingCode(CODE);

const log = (...a: unknown[]) =>
  console.log(new Date().toISOString().slice(11, 23), ...a);

async function main() {
  const appKeys = await KeyPair.generate();

  // Node 22 native WebSocket (no npm deps).
  const ws = new WebSocket(RELAY_URL);
  await new Promise<void>((res, rej) => {
    ws.onopen = () => res();
    ws.onerror = (e) => rej(new Error("ws error " + JSON.stringify(e)));
  });
  log("connected to relay");

  ws.send(JSON.stringify({ type: "join", channel, role: "app" }));

  let agentPub: Buffer | null = null;
  let sendKey: Buffer | null = null;
  let recvKey: Buffer | null = null;
  let sendSeq = 0;
  const pending = new Map<number, (v: unknown) => void>();

  const wsSend = (obj: unknown) => ws.send(JSON.stringify(obj));
  const sendPub = () => {
    wsSend({
      type: "data", channel,
      payload: Buffer.from(appKeys.publicBytes).toString("base64"),
    });
    log("app public key sent");
  };

  ws.onmessage = (ev) => {
    const raw = String(ev.data);
    let parsed: any;
    try { parsed = JSON.parse(raw); } catch { return; }

    if (parsed.type === "joined") { log("joined channel", parsed.channel); }
    else if (parsed.type === "paired") { log("paired (both endpoints present)"); }
    else if (parsed.type === "error") { log("RELAY ERROR:", parsed.message); }
    else if (parsed.type === "data") {
      const payload = String(parsed.payload ?? "");
      // Possible raw public key frame (agent sends before encryption).
      if (payload.length === 44 && /^[A-Za-z0-9+/=]+$/.test(payload)) {
        agentPub = Buffer.from(payload, "base64");
        if (sendKey === null && !agentKeyDeriving) {
          deriveAndReply();
        }
        return;
      }
      // Encrypted frame.
      if (recvKey) {
        try {
          const { sequence, plaintext } = decryptWithSeq(payload, recvKey);
          const rpc = JSON.parse(plaintext.toString());
          if (rpc.id != null && pending.has(rpc.id)) {
            pending.get(rpc.id)!(rpc.result);
            pending.delete(rpc.id);
          } else if (rpc.method === "event") {
            log("EVENT:", (rpc.params as any)?.type,
                JSON.stringify(rpc.params).slice(0, 140));
          } else {
            log("UNSOLICITED:", JSON.stringify(rpc).slice(0, 120));
          }
        } catch (e) {
          log("decrypt fail:", (e as Error).message.slice(0, 90));
        }
      } else {
        log("data frame before keys derived — length", payload.length);
      }
    }
  };

  let agentKeyDeriving = false;
  async function deriveAndReply() {
    if (agentKeyDeriving || sendKey) return;
    agentKeyDeriving = true;
    const secret = await computeSharedSecret(
      appKeys.privateBytes, agentPub!, Buffer.from(CODE),
    );
    sendKey = deriveEncKey(secret, "app_to_agent");
    recvKey = deriveEncKey(secret, "agent_to_app");
    log("keys derived: send(app→agent)", sendKey.toString("hex").slice(0, 12) + "…");
    sendPub();
  }

  async function call(method: string, params: Record<string, unknown> = {}) {
    while (!sendKey) await new Promise((r) => setTimeout(r, 50));
    const id = Math.floor(Math.random() * 1e6);
    const done = new Promise<unknown>((res) => pending.set(id, res));
    const wire = encryptJsonRpc(
      { jsonrpc: "2.0", id, method, params },
      sendKey!, sendSeq, channel,
    );
    sendSeq++;
    wsSend({ type: "data", channel, payload: wire });
    return done;
  }

  // ── Test sequence ──────────────────────────────────────────────────────
  log("waiting for agent key exchange…");
  const waitKeys = async () => {
    while (!agentPub) await new Promise((r) => setTimeout(r, 100));
  };
  await waitKeys();
  // wait for derived keys
  await deriveAndReply();

  // agent should now send its encrypted "paired" event
  await new Promise((r) => setTimeout(r, 1200));

  log("── profiles.list ──");
  const profiles = await call("profiles.list", { include_sessions: true });
  log("profiles:", JSON.stringify(profiles).slice(0, 300));

  log("── profiles.create (v2: bot = profile) ──");
  const botName = "e2ebot" + Math.floor(Math.random() * 900 + 100);
  const createdBot = await call("profiles.create", {
    name: botName, description: "E2E test bot", soul: "You are a terse test bot.",
  });
  log("created:", JSON.stringify(createdBot).slice(0, 200));

  log("── session.create ON THE NEW PROFILE ──");
  const created = await call("session.create", {
    profile: botName, title: "e2e-sdk-test",
  });
  log("created:", JSON.stringify(created).slice(0, 200));

  log("── prompt.submit ──");
  const sid = (created as any)?.session_id ?? (created as any)?.result?.session_id;
  const submitRes = await call("prompt.submit", { session_id: sid, text: "Reply OK" });
  log("submit:", JSON.stringify(submitRes).slice(0, 200));

  log("waiting 12s for stream events…");
  await new Promise((r) => setTimeout(r, 12000));

  log("── profiles.list (after) ──");
  const profiles2 = await call("profiles.list", { include_sessions: true });
  const all = (profiles2 as any)?.profiles ?? [];
  const botRow = all.find((p: any) => p.name === botName);
  log("bot row present:", !!botRow, "| display:", botRow?.display_name,
      "| last_session:", JSON.stringify(botRow?.last_session).slice(0, 120));

  log("── session.list (sanity) ──");
  const list = await call("session.list");
  log("session count:", JSON.stringify(list).length, "bytes");

  ws.close();
  log("E2E COMPLETE — channel", channel);
}

main().catch((e) => { console.error("E2E FAIL:", e); process.exit(1); });
#!/usr/bin/env python3
"""Nexus Agent CLI — one-command setup, pairing and supervision.

Install once, then:
  nexus-agent setup                     # interactive: relay URL + pairing code
  nexus-agent pair                      # generate a code and wait for the app
  nexus-agent start                     # run in the background (supervised)
  nexus-agent status                    # is it running?
  nexus-agent stop                      # stop it
  nexus-agent update                    # pull latest code and restart

Configuration is stored in ~/.nexus/config.yaml (0600). The agent itself is
relay_agent.py's MobileRelayClient — this CLI only manages config, pairing
and the background process.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml

# Allow running from a source checkout without install
RELAY_DIR = Path(__file__).resolve().parent
if str(RELAY_DIR) not in sys.path:
    sys.path.insert(0, str(RELAY_DIR))

# Allow NEXUS_INSTALL_DIR to override the default location (used by
# install-agent.sh and for test isolation).
_INSTALL_DIR = os.environ.get("NEXUS_INSTALL_DIR") or str(Path.home() / ".nexus")
CONFIG_DIR = Path(_INSTALL_DIR)
CONFIG_PATH = CONFIG_DIR / "config.yaml"
LOG_PATH = CONFIG_DIR / "mobile-agent.log"
PID_PATH = CONFIG_DIR / "agent.pid"
AGENT_SCRIPT = RELAY_DIR / "relay_agent.py"

DEFAULT_VENV = CONFIG_DIR / "venv"


def log(msg: str) -> None:
    print(f"[nexus-agent] {msg}", flush=True)


# ---------------------------------------------------------------- config ---

def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {}
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f) or {}


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".yaml.tmp")
    tmp.write_text(yaml.safe_dump(cfg, default_flow_style=False))
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_PATH)


def read_pid() -> int | None:
    if not PID_PATH.exists():
        return None
    try:
        return int(PID_PATH.read_text().strip())
    except (ValueError, OSError):
        return None


def _pid_is_agent(pid: int) -> bool:
    """Verify the pid actually runs relay_agent.py --daemon (identity check).

    Guards against a stale pidfile whose pid was reused by an unrelated
    process — stop() must never SIGKILL a stranger.
    """
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=3,
        ).stdout
        cmd = out.strip()
        return "relay_agent.py" in cmd and "--daemon" in cmd
    except Exception:
        return False


def is_running() -> bool:
    pid = read_pid()
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return _pid_is_agent(pid)


# -------------------------------------------------------------- commands ---

def cmd_setup(args) -> int:
    cfg = load_config()
    print("Nexus Agent setup — leave a field empty to keep its current value.\n")
    if "relay" not in cfg or args.force or args.relay:
        cur = cfg.get("relay", "")
        val = (args.relay or "").strip() or input(f"Relay URL [{cur}]: ").strip() or cur
        if not val.startswith(("wss://", "ws://")):
            log("ERROR: relay URL must start with wss:// (or ws:// for local test)")
            return 1
        cfg["relay"] = val
    if "code" not in cfg or args.force or args.code:
        cur = cfg.get("code", "")
        val = (args.code or "").strip().upper() or input(f"Pairing code (8+ chars, e.g. K7M2P9QX) [{cur}]: ").strip().upper() or cur
        if not (8 <= len(val) <= 12) or not val.replace("-", "").isalnum():
            log("ERROR: pairing code must be 8-12 alphanumeric chars")
            return 1
        cfg["code"] = val
    if "dashboard" not in cfg or args.force or args.dashboard is not None:
        cur = cfg.get("dashboard", "")
        if args.dashboard is not None:
            # Explicit override (may be empty to clear)
            val = args.dashboard.strip()
        else:
            # Env-first: the dashboard WS URL carries a session token — it
            # must not land in argv/ps/history when it can come from env.
            env_val = os.environ.get("HERMES_DASHBOARD_WS", "")
            if env_val:
                val = env_val
            else:
                val = input("Dashboard WS URL with token (HERMES_DASHBOARD_WS) []: ").strip() or cur
        cfg["dashboard"] = val
    save_config(cfg)
    log(f"Saved config to {CONFIG_PATH}")
    log("Next: run 'nexus-agent pair' to wait for the app (or 'nexus-agent start' if already paired).")
    return 0


def cmd_pair(args) -> int:
    cfg = load_config()
    relay = args.relay or cfg.get("relay")
    code = args.code or cfg.get("code")
    dash = args.dashboard or cfg.get("dashboard") or os.environ.get("HERMES_DASHBOARD_WS", "")
    if args.qr:
        # Consume a phone-generated QR payload: nexus://<relay>?code=X[&name=Y]
        parsed = _parse_qr_payload(args.qr)
        if parsed is None:
            log("ERROR: invalid QR payload — expected nexus://<relay>?code=<CODE>")
            return 1
        relay, code, name = parsed
        if name:
            log(f"Server name from QR: {name}")
    if not relay:
        log("ERROR: no relay URL configured — run 'nexus-agent setup' first")
        return 1
    if not code:
        log("ERROR: no pairing code configured — run 'nexus-agent setup' first")
        return 1
    if args.save:
        cfg["relay"] = relay
        cfg["code"] = code
        if dash:
            cfg["dashboard"] = dash
        save_config(cfg)

    log(f"Relay: {relay}")
    log(f"Pairing code: {code}")
    log("Waiting for the app… (leave this terminal open)")
    return _run_foreground(relay, code, dash)


def cmd_start(args) -> int:
    cfg = load_config()
    relay = cfg.get("relay")
    dash = cfg.get("dashboard") or os.environ.get("HERMES_DASHBOARD_WS", "")
    if not relay:
        log("ERROR: no relay configured — run 'nexus-agent setup' first")
        return 1
    if is_running():
        log(f"already running (pid {read_pid()})")
        return 0
    # Start the agent in the background via the venv's python
    python = _python_bin()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    PID_PATH.unlink(missing_ok=True)  # drop any stale pidfile
    proc = subprocess.Popen(
        [python, str(AGENT_SCRIPT), "--relay", relay, "--daemon",
         "--log-file", str(LOG_PATH), "--pidfile", str(PID_PATH)],
        env={**os.environ, "HERMES_DASHBOARD_WS": dash},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    # The daemon double-forks and writes ITS OWN pidfile; wait for it and
    # verify identity (avoids recording the intermediate fork's pid).
    pid = None
    for _ in range(50):
        time.sleep(0.1)
        candidate = read_pid()
        if candidate is not None and _pid_is_agent(candidate):
            pid = candidate
            break
    if pid is None:
        log("ERROR: daemon did not come up — last log lines:")
        _tail_log()
        return 1
    log(f"started (pid {pid}); logs: {LOG_PATH}")
    log("Run 'nexus-agent status' to check.")
    return 0


def cmd_status(args) -> int:
    pid = read_pid()
    if pid and is_running():
        log(f"running (pid {pid})")
        log(f"relay: {load_config().get('relay', '?')}")
        log(f"logs: {LOG_PATH}")
        return 0
    log("not running")
    return 1


def cmd_stop(args) -> int:
    pid = read_pid()
    if pid is None:
        log("not running")
        return 0
    # Identity check — never signal a pid that isn't our agent.
    if not _pid_is_agent(pid):
        log(f"pid {pid} is not the nexus agent (stale pidfile?) — removing pidfile")
        PID_PATH.unlink(missing_ok=True)
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    # Wait for exit
    for _ in range(30):
        if not is_running():
            break
        time.sleep(0.2)
    if is_running():
        log("did not stop cleanly — sending SIGKILL")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    PID_PATH.unlink(missing_ok=True)
    log("stopped")
    return 0


def _tail_log(n: int = 20) -> None:
    try:
        lines = LOG_PATH.read_text().splitlines()[-n:]
        for line in lines:
            print(f"  {line}", file=sys.stderr)
    except OSError:
        print("  (no log file)", file=sys.stderr)


def cmd_update(args) -> int:
    # Self-update: pull latest from the repo (works in a git checkout).
    # The .git dir lives at the checkout root (RELAY_DIR.parent for both the
    # source layout repo/relay/ and the installer's ~/.nexus/relay/relay/).
    git_root = RELAY_DIR.parent
    if not (git_root / ".git").exists():
        log("not a git checkout — update not supported; re-run the installer")
        return 1
    log("pulling latest…")
    r = subprocess.run(["git", "-C", str(git_root), "fetch", "--depth", "1", "origin", "HEAD"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        log(f"fetch failed: {r.stderr.strip()}")
        return 1
    # Reset to the fetched tip (works on detached HEAD, keeps sparse cone)
    r = subprocess.run(["git", "-C", str(git_root), "reset", "--hard", "FETCH_HEAD"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        log(f"reset failed: {r.stderr.strip()}")
        return 1
    # Restart if running
    was_running = is_running()
    if was_running:
        cmd_stop(argparse.Namespace())
        time.sleep(0.5)
        cmd_start(argparse.Namespace())
        log("updated and restarted")
    else:
        log("updated (agent not running)")
    return 0


# ---------------------------------------------------------------- helpers ---

def _python_bin() -> str:
    """Prefer a dedicated venv if it exists, else the current interpreter."""
    py = DEFAULT_VENV / "bin" / "python"
    if py.exists():
        return str(py)
    return sys.executable


def _parse_qr_payload(payload: str) -> tuple[str, str, str] | None:
    """Parse a phone-generated pairing QR: nexus://<relay>?code=X[&name=Y].

    The relay part may itself carry a scheme (the phone emits
    'nexus://wss://relay.example.com/relay?...'). Returns (relay_url, code,
    name) or None on invalid input.
    """
    try:
        from urllib.parse import parse_qs, urlparse
        # Normalize an embedded scheme: nexus://wss://host/path -> nexus://host/path
        norm = payload
        if "://" in norm:
            prefix, rest = norm.split("://", 1)
            for inner in ("wss://", "ws://"):
                if prefix == "nexus" and rest.startswith(inner):
                    norm = f"nexus://{rest[len(inner):]}"
                    break
        u = urlparse(norm)
        if u.scheme != "nexus" or not u.netloc:
            return None
        qs = parse_qs(u.query)
        codes = qs.get("code", [])
        if not codes:
            return None
        code = codes[0].upper()
        # Same rule as cmd_setup/relay_agent: 8-12 alphanumeric (dashes ok)
        if not (8 <= len(code) <= 12) or not code.replace("-", "").isalnum():
            return None
        relay = f"wss://{u.netloc}{u.path}"
        name = qs.get("name", [""])[0]
        return relay, code, name
    except Exception:
        return None


def _run_foreground(relay: str, code: str, dash: str) -> int:
    python = _python_bin()
    env = {**os.environ, "HERMES_DASHBOARD_WS": dash}
    r = subprocess.run([python, str(AGENT_SCRIPT), "--relay", relay, "--pair", "--code", code], env=env)
    return r.returncode


def main() -> int:
    parser = argparse.ArgumentParser(prog="nexus-agent", description="Nexus mobile agent — install, pair, supervise")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_setup = sub.add_parser("setup", help="interactive configuration (relay URL, pairing code, dashboard)")
    p_setup.add_argument("--force", action="store_true", help="re-ask all fields")
    p_setup.add_argument("--relay", help="set relay URL non-interactively")
    p_setup.add_argument("--code", help="set pairing code non-interactively")
    p_setup.add_argument("--dashboard", help="set dashboard WS URL non-interactively")
    p_setup.set_defaults(func=cmd_setup)

    p_pair = sub.add_parser("pair", help="show the pairing code and wait for the app")
    p_pair.add_argument("--relay", help="override configured relay URL")
    p_pair.add_argument("--code", help="override pairing code")
    p_pair.add_argument("--dashboard", help="override dashboard WS URL")
    p_pair.add_argument("--save", action="store_true", help="persist overrides into config")
    p_pair.add_argument("--qr", help="consume a phone-generated QR payload: nexus://<relay>?code=X")
    p_pair.set_defaults(func=cmd_pair)

    p_start = sub.add_parser("start", help="run the agent in the background")
    p_start.set_defaults(func=cmd_start)

    p_status = sub.add_parser("status", help="check whether the agent is running")
    p_status.set_defaults(func=cmd_status)

    p_stop = sub.add_parser("stop", help="stop the background agent")
    p_stop.set_defaults(func=cmd_stop)

    p_update = sub.add_parser("update", help="pull latest code and restart")
    p_update.set_defaults(func=cmd_update)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

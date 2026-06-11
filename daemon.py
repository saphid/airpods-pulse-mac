#!/usr/bin/env python3
"""
airpods-pulse-mac daemon

- Opens and maintains the reverse SSH tunnel to the remote server
- Watches PulseAudio for recording activity
- When recording starts (source → RUNNING), switches Mac input to the
  configured Bluetooth mic; when it stops, restores the previous input

Config: ~/.config/airpods-pulse-mac/config
Log:    ~/Library/Logs/airpods-pulse-mac.log  (or stdout when run manually)
"""

import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

CONFIG_FILE = Path.home() / ".config/airpods-pulse-mac/config"

DEFAULTS = {
    "MIC_DEVICE": "",
    "SERVER": "",
    "PACTL": "/usr/local/bin/pactl",
    "SWITCH_AUDIO": "/usr/local/bin/SwitchAudioSource",
    "RECONNECT_DELAY": "3",
    "TUNNEL_RETRY_DELAY": "10",
}


def load_config():
    cfg = dict(DEFAULTS)
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip().strip("\"'")
    return cfg


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts}  {msg}", flush=True)


# ── SSH tunnel ────────────────────────────────────────────────────────────────

def run_tunnel(server, retry_delay):
    """Keeps the reverse SSH tunnel alive. Runs in a background thread."""
    ssh = "/usr/bin/ssh"
    while True:
        log(f"tunnel: connecting to {server}…")
        proc = subprocess.Popen(
            [ssh, "-N",
             "-o", "ServerAliveInterval=30",
             "-o", "ServerAliveCountMax=3",
             "-o", "ExitOnForwardFailure=yes",
             "-o", "BatchMode=yes",
             "-R", "4713:127.0.0.1:4713",
             server],
            stderr=subprocess.PIPE,
            text=True,
        )
        # Stream stderr so connection errors appear in the log
        for line in proc.stderr:
            line = line.rstrip()
            if line:
                log(f"tunnel: {line}")
        rc = proc.wait()
        log(f"tunnel: exited (rc={rc}), retrying in {retry_delay}s…")
        time.sleep(retry_delay)


# ── PulseAudio watcher ────────────────────────────────────────────────────────

def source_states(pactl):
    r = subprocess.run([pactl, "list", "sources", "short"],
                       capture_output=True, text=True)
    states = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 5:
            name, state = parts[1], parts[4]
            if not name.endswith(".monitor"):
                states[name] = state
    return states


def any_recording(pactl):
    return any(s == "RUNNING" for s in source_states(pactl).values())


def current_input(switch_audio):
    r = subprocess.run([switch_audio, "-t", "input", "-c"],
                       capture_output=True, text=True)
    return r.stdout.strip()


def set_input(switch_audio, device):
    subprocess.run([switch_audio, "-t", "input", "-n", device],
                   capture_output=True)


def run_watcher(pactl, switch_audio, mic_device, reconnect_delay):
    saved_input = None
    was_recording = False

    while True:
        try:
            proc = subprocess.Popen([pactl, "subscribe"],
                                    stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                if "source" not in line:
                    continue
                recording = any_recording(pactl)
                if recording and not was_recording:
                    saved_input = current_input(switch_audio)
                    set_input(switch_audio, mic_device)
                    log(f"watcher: recording started — '{saved_input}' → '{mic_device}'")
                    was_recording = True
                elif not recording and was_recording:
                    if saved_input:
                        set_input(switch_audio, saved_input)
                        log(f"watcher: recording stopped — restored '{saved_input}'")
                    was_recording = False
        except Exception as e:
            log(f"watcher: error — {e}")

        if was_recording and saved_input:
            set_input(switch_audio, saved_input)
            was_recording = False
        log(f"watcher: PulseAudio disconnected, reconnecting in {reconnect_delay}s…")
        time.sleep(reconnect_delay)


# ── Main ──────────────────────────────────────────────────────────────────────

def handle_signal(signum, frame):
    log("Shutting down.")
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    cfg = load_config()
    pactl = cfg["PACTL"]
    switch_audio = cfg["SWITCH_AUDIO"]
    mic_device = cfg["MIC_DEVICE"]
    server = cfg["SERVER"]
    reconnect_delay = int(cfg["RECONNECT_DELAY"])
    tunnel_retry_delay = int(cfg["TUNNEL_RETRY_DELAY"])

    if not mic_device:
        log("ERROR: MIC_DEVICE not set in config — run install.sh")
        sys.exit(1)

    for binary in [pactl, switch_audio]:
        if not Path(binary).exists():
            log(f"ERROR: {binary} not found — run install.sh")
            sys.exit(1)

    log(f"Starting — mic: '{mic_device}', server: '{server or 'none (no tunnel)'}'")

    if server:
        t = threading.Thread(target=run_tunnel,
                             args=(server, tunnel_retry_delay),
                             daemon=True)
        t.start()
    else:
        log("watcher: no SERVER configured, skipping tunnel (manage it manually)")

    run_watcher(pactl, switch_audio, mic_device, reconnect_delay)


if __name__ == "__main__":
    main()

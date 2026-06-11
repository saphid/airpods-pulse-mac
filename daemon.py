#!/usr/bin/env python3
"""
airpods-pulse-mac daemon

Watches PulseAudio for recording activity. When a remote client starts
recording (source state → RUNNING), switches the Mac's audio input to the
configured Bluetooth mic. When recording stops, restores the previous input.

Config: ~/.config/airpods-pulse-mac/config
Log:    ~/Library/Logs/airpods-pulse-mac.log  (or stdout when run manually)
"""

import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

CONFIG_FILE = Path.home() / ".config/airpods-pulse-mac/config"
LOG_FILE = Path.home() / "Library/Logs/airpods-pulse-mac.log"

DEFAULTS = {
    "MIC_DEVICE": "",
    "PACTL": "/usr/local/bin/pactl",
    "SWITCH_AUDIO": "/usr/local/bin/SwitchAudioSource",
    "RECONNECT_DELAY": "3",
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
    line = f"{ts}  {msg}"
    print(line, flush=True)


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


def run(cfg):
    pactl = cfg["PACTL"]
    switch_audio = cfg["SWITCH_AUDIO"]
    mic_device = cfg["MIC_DEVICE"]
    reconnect_delay = int(cfg["RECONNECT_DELAY"])

    if not mic_device:
        log("ERROR: MIC_DEVICE not set in config. Run install.sh to configure.")
        sys.exit(1)

    for binary in [pactl, switch_audio]:
        if not Path(binary).exists():
            log(f"ERROR: {binary} not found. Run install.sh.")
            sys.exit(1)

    log(f"Starting — mic device: '{mic_device}'")

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
                    log(f"recording started — switched '{saved_input}' → '{mic_device}'")
                    was_recording = True
                elif not recording and was_recording:
                    if saved_input:
                        set_input(switch_audio, saved_input)
                        log(f"recording stopped — restored '{saved_input}'")
                    was_recording = False

        except Exception as e:
            log(f"pactl subscribe error: {e}")

        # pactl subscribe exited (PulseAudio restarted, etc.) — reconnect
        if was_recording and saved_input:
            set_input(switch_audio, saved_input)
            was_recording = False
        log(f"PulseAudio disconnected, reconnecting in {reconnect_delay}s…")
        time.sleep(reconnect_delay)


def handle_signal(signum, frame):
    log("Shutting down.")
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    cfg = load_config()
    run(cfg)

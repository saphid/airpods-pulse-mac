# airpods-pulse-mac

Automatically switch your Mac's audio input to AirPods (or any Bluetooth mic) when a remote server starts recording via PulseAudio over SSH — and switch back when it stops.

**Primary use case:** [Claude Code voice mode](https://docs.anthropic.com/en/docs/claude-code/voice-dictation) running on a remote Linux server, with your AirPods on your Mac.

---

## How it works

```
MacBook Air                              Remote server
─────────────────────────────            ──────────────────────
daemon.py
  ├─ thread: SSH reverse tunnel  ──────► port 4713 (PulseAudio TCP)
  │   (auto-reconnects on drop)
  │
  └─ thread: pactl subscribe
       ├─ source → RUNNING   →  SwitchAudioSource → AirPods (mic on)
       └─ source → SUSPENDED →  SwitchAudioSource → restore previous input
```

A single background daemon manages both the SSH tunnel and the mic switching. When the remote client begins recording (PulseAudio source → RUNNING), it switches your Mac's input to the configured Bluetooth mic. When recording ends, it restores whatever was the input before. No key interception, no manual toggling, no second terminal.

---

## Prerequisites

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- AirPods (or any Bluetooth headset) connected to your Mac
- A remote Linux server accessible via SSH

---

## Installation

```bash
git clone https://github.com/yourusername/airpods-pulse-mac
cd airpods-pulse-mac
bash install.sh
```

The installer will:
1. Install `pulseaudio` and `switchaudio-osx` via Homebrew if needed
2. Start PulseAudio and configure it to accept localhost TCP connections on port 4713
3. Let you pick the audio input device to use for recording
4. Install and start a background daemon (auto-restarts on login)

---

## Setup: remote server

Add to `~/.bashrc` (or `~/.zshrc`) on the remote server:

```bash
export PULSE_SERVER=tcp:127.0.0.1:4713
```

---

## Usage

After installation, the daemon runs automatically in the background and manages the tunnel. There's nothing to start manually.

**SSH to your server and run Claude Code:**

```bash
ssh you@your-server
claude
```

Hold Space to talk. The daemon opens the tunnel, watches for recording activity, and switches your mic to AirPods automatically.

> **Note:** macOS drops AirPods to phone-call audio quality while the mic is active — this is a Bluetooth limitation. The install script verifies the mic switch works; if it can't, it will tell you what to do.

---

## Changing the mic device

Edit `~/.config/airpods-pulse-mac/config` and update `MIC_DEVICE`, then restart the daemon:

```bash
launchctl kickstart -k "gui/$(id -u)/com.github.airpods-pulse-mac"
```

Or run `bash install.sh` again to reconfigure interactively.

---

## Logs

```bash
tail -f ~/Library/Logs/airpods-pulse-mac.log
```

---

## Uninstall

```bash
bash uninstall.sh
```

---

## Troubleshooting

**`pactl: command not found`**
PulseAudio isn't installed or `/usr/local/bin` isn't in your PATH. Run `brew install pulseaudio`.

**Daemon starts but mic doesn't switch**
Check that the SSH tunnel is open (`ss -tnlp | grep 4713` on the server should show a listener) and that `PULSE_SERVER` is set in your shell.

**"Connection refused" from server**
The tunnel isn't running. Start it on your Mac: `ssh -N -R 4713:127.0.0.1:4713 you@server`.

**AirPods not in the device list**
AirPods must be connected to the Mac and set as the input device in System Settings → Sound → Input at least once before the daemon can switch to them.

---

## License

MIT

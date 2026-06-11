#!/usr/bin/env bash
# airpods-pulse-mac installer
# Sets up automatic AirPods mic switching for remote PulseAudio clients.

set -euo pipefail

LABEL="com.github.airpods-pulse-mac"
CONFIG_DIR="$HOME/.config/airpods-pulse-mac"
CONFIG_FILE="$CONFIG_DIR/config"
INSTALL_DIR="$HOME/.local/share/airpods-pulse-mac"
DAEMON="$INSTALL_DIR/daemon.py"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/airpods-pulse-mac.log"

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)

info()    { echo "${GREEN}▶${RESET} $*"; }
warn()    { echo "${YELLOW}!${RESET} $*"; }
error()   { echo "${RED}✗${RESET} $*" >&2; exit 1; }
section() { echo; echo "${BOLD}$*${RESET}"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

section "Checking prerequisites"

if ! command -v brew &>/dev/null; then
    error "Homebrew not found. Install it first: https://brew.sh"
fi
info "Homebrew: ok"

for pkg in pulseaudio switchaudio-osx; do
    if brew list "$pkg" &>/dev/null; then
        info "$pkg: already installed"
    else
        info "Installing $pkg…"
        brew install "$pkg"
    fi
done

# ── PulseAudio ────────────────────────────────────────────────────────────────

section "Configuring PulseAudio"

if ! brew services list | grep pulseaudio | grep -q started; then
    info "Starting PulseAudio service…"
    brew services start pulseaudio
    sleep 3
else
    info "PulseAudio service: running"
fi

for i in $(seq 1 10); do
    if pactl info &>/dev/null 2>&1; then break; fi
    sleep 1
done
pactl info &>/dev/null 2>&1 || error "PulseAudio didn't start. Check: brew services list"

PULSE_CONFIG_DIR="$HOME/.config/pulse"
DEFAULT_PA="$PULSE_CONFIG_DIR/default.pa"
mkdir -p "$PULSE_CONFIG_DIR"

TCP_MODULE_LINE="load-module module-native-protocol-tcp port=4713 auth-ip-acl=127.0.0.1"

if [[ ! -f "$DEFAULT_PA" ]]; then
    SYSTEM_DEFAULT="/usr/local/etc/pulse/default.pa"
    if [[ -f "$SYSTEM_DEFAULT" ]]; then
        cp "$SYSTEM_DEFAULT" "$DEFAULT_PA"
    else
        echo "#!/usr/bin/pulseaudio -nF" > "$DEFAULT_PA"
        echo ".include /usr/local/etc/pulse/default.pa" >> "$DEFAULT_PA"
    fi
fi

if ! grep -qF "$TCP_MODULE_LINE" "$DEFAULT_PA"; then
    echo "" >> "$DEFAULT_PA"
    echo "# airpods-pulse-mac: allow SSH-tunneled connections on localhost" >> "$DEFAULT_PA"
    echo "$TCP_MODULE_LINE" >> "$DEFAULT_PA"
    info "Added TCP module to $DEFAULT_PA"
else
    info "TCP module already in default.pa"
fi

if ! pactl list modules short | grep -q module-native-protocol-tcp; then
    pactl load-module module-native-protocol-tcp port=4713 auth-ip-acl=127.0.0.1
    info "TCP module loaded (port 4713)"
else
    info "TCP module: already loaded"
fi

# ── Detect mic device ─────────────────────────────────────────────────────────

section "Selecting microphone"

INPUTS=()
while IFS= read -r line; do
    INPUTS+=("$line")
done < <(SwitchAudioSource -a -t input)

[[ ${#INPUTS[@]} -eq 0 ]] && error "No audio input devices found."

echo "Available input devices:"
for i in "${!INPUTS[@]}"; do
    echo "  $((i+1))) ${INPUTS[$i]}"
done
echo

CURRENT_MIC=""
if [[ -f "$CONFIG_FILE" ]]; then
    CURRENT_MIC=$(grep "^MIC_DEVICE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
fi

if [[ -n "$CURRENT_MIC" ]]; then
    warn "Currently configured: '$CURRENT_MIC'"
    read -rp "Keep this device? [Y/n] " KEEP
    if [[ "${KEEP:-y}" =~ ^[Yy]$ ]]; then
        MIC_DEVICE="$CURRENT_MIC"
    else
        CURRENT_MIC=""
    fi
fi

if [[ -z "$CURRENT_MIC" ]]; then
    read -rp "Enter device number (or type a name): " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#INPUTS[@]} )); then
        MIC_DEVICE="${INPUTS[$((CHOICE-1))]}"
    else
        MIC_DEVICE="$CHOICE"
    fi
fi

info "Mic device: '$MIC_DEVICE'"

# Verify the device can actually be activated (forces HFP negotiation)
ORIGINAL_INPUT=$(SwitchAudioSource -t input -c)
if [[ "$ORIGINAL_INPUT" != "$MIC_DEVICE" ]]; then
    echo
    info "Testing mic switch (this establishes the Bluetooth HFP connection)…"
    SwitchAudioSource -t input -n "$MIC_DEVICE" 2>/dev/null || true
    sleep 3
    ACTUAL=$(SwitchAudioSource -t input -c)
    if [[ "$ACTUAL" == "$MIC_DEVICE" ]]; then
        info "Mic switch: ok — HFP connection established"
        SwitchAudioSource -t input -n "$ORIGINAL_INPUT" 2>/dev/null || true
    else
        warn "Could not switch to '$MIC_DEVICE' automatically."
        warn "One-time fix: open System Settings → Sound → Input and select '$MIC_DEVICE'."
        warn "After that, the daemon handles all switching automatically."
    fi
fi

# ── SSH server ────────────────────────────────────────────────────────────────

section "SSH tunnel server"

CURRENT_SERVER=""
if [[ -f "$CONFIG_FILE" ]]; then
    CURRENT_SERVER=$(grep "^SERVER=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
fi

if [[ -n "$CURRENT_SERVER" ]]; then
    warn "Currently configured: '$CURRENT_SERVER'"
    read -rp "Keep this server? [Y/n] " KEEP
    if [[ "${KEEP:-y}" =~ ^[Yy]$ ]]; then
        SERVER="$CURRENT_SERVER"
    else
        CURRENT_SERVER=""
    fi
fi

if [[ -z "$CURRENT_SERVER" ]]; then
    read -rp "SSH connection string (e.g. user@hostname), or Enter to skip: " SERVER
fi

if [[ -n "$SERVER" ]]; then
    info "Server: '$SERVER'"
else
    warn "No server configured — tunnel will not be managed (set SERVER in config later)"
fi

# ── Write config ──────────────────────────────────────────────────────────────

section "Writing config"

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
# airpods-pulse-mac config
# After editing, restart the agent:
#   launchctl kickstart -k "gui/$(id -u)/$LABEL"

MIC_DEVICE="$MIC_DEVICE"
SERVER="$SERVER"
PACTL="/usr/local/bin/pactl"
SWITCH_AUDIO="/usr/local/bin/SwitchAudioSource"
RECONNECT_DELAY="3"
TUNNEL_RETRY_DELAY="10"
EOF
info "Config written to $CONFIG_FILE"

# ── Install daemon ────────────────────────────────────────────────────────────

section "Installing daemon"

mkdir -p "$INSTALL_DIR"
cp "$(dirname "$0")/daemon.py" "$DAEMON"
chmod +x "$DAEMON"
info "Daemon installed to $DAEMON"

# ── LaunchAgent ───────────────────────────────────────────────────────────────

section "Installing LaunchAgent"

PULSE_SOCKET=$(pactl info | awk '/^Server String:/{print $NF}')

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$DAEMON</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PULSE_SERVER</key>
        <string>$PULSE_SOCKET</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
info "LaunchAgent loaded"

# ── Done ──────────────────────────────────────────────────────────────────────

section "Done"

echo
echo "  The daemon is running and manages the SSH tunnel automatically."
echo "  Logs: tail -f $LOG_FILE"
echo
echo "  On the remote server, add to ~/.bashrc if not already present:"
echo "    ${GREEN}export PULSE_SERVER=tcp:127.0.0.1:4713${RESET}"
echo
echo "  Then ${BOLD}ssh $SERVER${RESET} and run ${BOLD}claude${RESET} — hold Space to talk."
echo
echo

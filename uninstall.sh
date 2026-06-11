#!/usr/bin/env bash
# airpods-pulse-mac uninstaller

set -euo pipefail

LABEL="com.github.airpods-pulse-mac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/.local/share/airpods-pulse-mac"
CONFIG_DIR="$HOME/.config/airpods-pulse-mac"

echo "Uninstalling airpods-pulse-mac…"

# Stop and remove LaunchAgent
if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  Removed LaunchAgent"
fi

# Remove daemon
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "  Removed daemon"
fi

echo
read -rp "Remove config and logs too? [y/N] " CLEAN
if [[ "$CLEAN" =~ ^[Yy]$ ]]; then
    rm -rf "$CONFIG_DIR"
    rm -f "$HOME/Library/Logs/airpods-pulse-mac.log"
    echo "  Removed config and logs"
fi

echo
echo "Uninstalled. PulseAudio and its TCP module are left intact."
echo "To fully remove PulseAudio: brew services stop pulseaudio && brew uninstall pulseaudio"

#!/bin/bash
set -u

SYNERGY_PLIST="$HOME/Library/LaunchAgents/com.symless.synergy3.plist"
BACKUP="$SYNERGY_PLIST.bak"

WATCHER_PLIST="$HOME/Library/LaunchAgents/com.synergy.qos-watcher.plist"
WATCHER_DIR="$HOME/.synergy-qos-fix"

UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
SYNERGY_LABEL="com.symless.synergy3"
WATCHER_LABEL="com.synergy.qos-watcher"

echo "===================================================="
echo "Synergy 3 macOS QoS Fix — uninstaller"
echo "===================================================="
echo ""

echo "1) Removing QoS watcher..."
launchctl bootout "$DOMAIN/$WATCHER_LABEL" 2>/dev/null || true
rm -f "$WATCHER_PLIST"
rm -rf "$WATCHER_DIR"
echo "   Watcher removed."
echo ""

echo "2) Restoring original Synergy plist..."

if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$SYNERGY_PLIST"
    echo "   Original plist restored from:"
    echo "   $BACKUP"
else
    echo "   Backup not found; removing ProcessType if present."
    /usr/libexec/PlistBuddy -c "Delete :ProcessType" "$SYNERGY_PLIST" 2>/dev/null || true
fi

if [ -f "$SYNERGY_PLIST" ]; then
    /usr/bin/plutil -lint "$SYNERGY_PLIST"
fi

echo ""

echo "3) Restarting Synergy..."

launchctl bootout "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null || true

for name in synergy-core synergy-service synergy-tray synergy-security Synergy; do
    pids="$(ps -axo pid=,comm= | awk -v n="$name" 'BEGIN{IGNORECASE=1} $2 ~ n {print $1}')"
    if [ -n "$pids" ]; then
        echo "   Killing $name: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

sleep 1

if launchctl bootstrap "$DOMAIN" "$SYNERGY_PLIST" 2>/dev/null; then
    echo "   Synergy started."
elif launchctl kickstart -k "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null; then
    echo "   Synergy restarted."
else
    echo "   WARNING: Could not start Synergy automatically."
    echo "   You can open Synergy manually."
fi

echo ""
echo "4) Verification..."

if [ -f "$SYNERGY_PLIST" ]; then
    CURRENT=$(/usr/libexec/PlistBuddy -c "Print :ProcessType" "$SYNERGY_PLIST" 2>/dev/null || true)
    if [ -z "$CURRENT" ]; then
        echo "   ProcessType: removed (original state)"
    else
        echo "   ProcessType: $CURRENT"
    fi
fi

if launchctl print "$DOMAIN/$WATCHER_LABEL" >/dev/null 2>&1; then
    echo "   WARNING: watcher is still loaded."
else
    echo "   Watcher: removed"
fi

echo ""
echo "===================================================="
echo "UNINSTALL COMPLETE"
echo "===================================================="
echo "The QoS watcher has been removed."
echo "The original Synergy plist has been restored."
echo ""
echo "Backup kept at:"
echo "  $BACKUP"
echo "===================================================="

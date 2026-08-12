#!/bin/bash
set -u
set -e

# ============================================================
# Synergy 3 macOS QoS Fix — automatic installer
#
# Sets ProcessType=Interactive for Synergy's LaunchAgent and
# installs a launchd WatchPaths watcher that restores the value
# if Synergy rewrites its plist.
#
# No polling loop, no Renice, no CPU limiting.
# ============================================================

SYNERGY_PLIST="$HOME/Library/LaunchAgents/com.symless.synergy3.plist"
BACKUP="$SYNERGY_PLIST.bak"

WATCHER_DIR="$HOME/.synergy-qos-fix"
WATCHER_SCRIPT="$WATCHER_DIR/watcher.sh"
WATCHER_PLIST="$HOME/Library/LaunchAgents/com.synergy.qos-watcher.plist"
WATCHER_LOG="$HOME/Library/Logs/synergy-qos-watcher.log"
WATCHER_ERR="$HOME/Library/Logs/synergy-qos-watcher-error.log"

UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
SYNERGY_LABEL="com.symless.synergy3"
WATCHER_LABEL="com.synergy.qos-watcher"

echo "===================================================="
echo "Synergy 3 macOS QoS Fix — automatic installer"
echo "===================================================="
echo ""

if [ ! -f "$SYNERGY_PLIST" ]; then
    echo "ERROR: Synergy LaunchAgent not found:"
    echo "  $SYNERGY_PLIST"
    echo ""
    echo "Launch Synergy 3 once, then run this installer again."
    exit 1
fi

mkdir -p "$WATCHER_DIR" "$HOME/Library/Logs"

echo "1) Removing previous watcher (if present)..."
launchctl bootout "$DOMAIN/$WATCHER_LABEL" 2>/dev/null || true
rm -f "$WATCHER_PLIST"
echo "   Done."
echo ""

echo "2) Stopping Synergy before editing its plist..."
launchctl bootout "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null || true

for name in synergy-core synergy-service synergy-tray synergy-security Synergy; do
    pids="$(ps -axo pid=,comm= | awk -v n="$name" 'BEGIN{IGNORECASE=1} $2 ~ n {print $1}')"
    if [ -n "$pids" ]; then
        echo "   Killing $name: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

sleep 1
echo "   Done."
echo ""

echo "3) Backing up Synergy plist..."
if [ ! -f "$BACKUP" ]; then
    cp "$SYNERGY_PLIST" "$BACKUP"
    echo "   Backup created: $BACKUP"
else
    echo "   Existing backup kept: $BACKUP"
fi

/usr/bin/plutil -lint "$SYNERGY_PLIST"
echo "   Plist valid."
echo ""

echo "4) Applying ProcessType = Interactive..."
if /usr/libexec/PlistBuddy -c "Print :ProcessType" "$SYNERGY_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :ProcessType Interactive" "$SYNERGY_PLIST"
else
    /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$SYNERGY_PLIST"
fi

/usr/bin/plutil -lint "$SYNERGY_PLIST"
echo "   Current value:"
/usr/libexec/PlistBuddy -c "Print :ProcessType" "$SYNERGY_PLIST"
echo ""

echo "5) Creating automatic watcher..."
cat > "$WATCHER_SCRIPT" <<'WATCHER_EOF'
#!/bin/bash
set -u

PLIST="$HOME/Library/LaunchAgents/com.symless.synergy3.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
SYNERGY_LABEL="com.symless.synergy3"

LOCKDIR="$HOME/.synergy-qos-fix/lock"
LOGFILE="$HOME/Library/Logs/synergy-qos-watcher.log"

log() {
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
}

[ -f "$PLIST" ] || exit 0

# Prevent overlapping watcher instances.
if ! /bin/mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi

cleanup() {
    /bin/rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Give an atomic plist replacement a moment to finish.
sleep 0.5

[ -f "$PLIST" ] || exit 0

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :ProcessType" "$PLIST" 2>/dev/null || true)

# Nothing to do if Synergy already has the correct value.
[ "$CURRENT" = "Interactive" ] && exit 0

log "ProcessType changed or missing; restoring Interactive."

# Stop Synergy before modifying its plist.
launchctl bootout "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null || true

for name in synergy-core synergy-service synergy-tray synergy-security Synergy; do
    pids="$(ps -axo pid=,comm= | awk -v n="$name" 'BEGIN{IGNORECASE=1} $2 ~ n {print $1}')"
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
done

sleep 0.5

[ -f "$PLIST" ] || exit 0

# Re-read after stopping Synergy.
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :ProcessType" "$PLIST" 2>/dev/null || true)

if [ "$CURRENT" != "Interactive" ]; then
    if [ -z "$CURRENT" ]; then
        /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$PLIST"
    else
        /usr/libexec/PlistBuddy -c "Set :ProcessType Interactive" "$PLIST"
    fi
fi

# Never restart Synergy from an invalid plist.
if ! /usr/bin/plutil -lint "$PLIST" >/dev/null 2>&1; then
    log "ERROR: plist validation failed; refusing to restart Synergy."
    exit 1
fi

if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    log "QoS fix reapplied; Synergy bootstrapped."
elif launchctl kickstart -k "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null; then
    log "QoS fix reapplied; Synergy kickstarted."
else
    log "ERROR: could not restart Synergy."
    exit 1
fi
WATCHER_EOF

chmod +x "$WATCHER_SCRIPT"
echo "   $WATCHER_SCRIPT"
echo ""

echo "6) Creating WatchPaths LaunchAgent..."
cat > "$WATCHER_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.synergy.qos-watcher</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WATCHER_SCRIPT</string>
    </array>

    <key>WatchPaths</key>
    <array>
        <string>$SYNERGY_PLIST</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>2</integer>

    <key>StandardOutPath</key>
    <string>$WATCHER_LOG</string>

    <key>StandardErrorPath</key>
    <string>$WATCHER_ERR</string>
</dict>
</plist>
PLIST_EOF

/usr/bin/plutil -lint "$WATCHER_PLIST"
echo "   $WATCHER_PLIST"
echo ""

echo "7) Loading watcher..."
launchctl bootstrap "$DOMAIN" "$WATCHER_PLIST"
echo "   Watcher loaded."
echo ""

echo "8) Starting Synergy..."
if launchctl bootstrap "$DOMAIN" "$SYNERGY_PLIST" 2>/dev/null; then
    echo "   Synergy bootstrapped."
elif launchctl kickstart -k "$DOMAIN/$SYNERGY_LABEL" 2>/dev/null; then
    echo "   Synergy kickstarted."
else
    echo "ERROR: Could not start Synergy."
    echo "See:"
    echo "  $HOME/Library/Logs/Synergy/com.symless.synergy3.log"
    echo "  $HOME/Library/Logs/Synergy/com.symless.synergy3_error.log"
    exit 1
fi

sleep 3

echo ""
echo "9) Final verification..."
echo "ProcessType:"
/usr/libexec/PlistBuddy -c "Print :ProcessType" "$SYNERGY_PLIST"

echo ""
echo "Watcher:"
launchctl print "$DOMAIN/$WATCHER_LABEL" >/dev/null 2>&1 \
    && echo "ACTIVE" \
    || echo "ERROR"

echo ""
echo "Synergy processes:"
ps -axo pid,ppid,ni,%cpu,comm,args | grep -i '[s]ynergy' || true

echo ""
echo "===================================================="
echo "DONE"
echo "===================================================="
echo "The QoS fix is applied."
echo "The watcher uses WatchPaths (no polling loop)."
echo "It restores ProcessType=Interactive if Synergy rewrites the plist."
echo ""
echo "Backup:"
echo "  $BACKUP"
echo ""
echo "Watcher log:"
echo "  $WATCHER_LOG"
echo "===================================================="

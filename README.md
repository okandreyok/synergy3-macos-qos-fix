# Synergy 3 macOS — QoS Fix

A community workaround for **Synergy 3 on macOS** that improves keyboard and mouse responsiveness under heavy CPU load.

## Problem

When the Mac running Synergy 3 is under heavy CPU contention, keyboard and mouse input sent to a Windows client can become delayed or less responsive.

The issue was reproduced with:

- Chrome + SilverBench
- Endurance
- Other CPU-saturating workloads

The severity depends on the workload.

## Cause

The actual QoS of `synergy-core` was inspected with:

```bash
sudo powermetrics --show-process-qos --samplers tasks
```

Before the workaround, `synergy-core` was observed at:

```text
Utility
```

After the workaround, it was observed at:

```text
Default
```

`synergy-core` handles the keyboard and mouse communication.

## Fix

Synergy 3 is launched through:

```text
~/Library/LaunchAgents/com.symless.synergy3.plist
```

The fix adds:

```xml
<key>ProcessType</key>
<string>Interactive</string>
```

This moves the observed QoS of `synergy-core` from **Utility** to **Default**.

The fix does not modify the Synergy binary.

## Results

| Workload | Result |
|---|---|
| Chrome + SilverBench at maximum load | Some input lag remains, but the system is more stable |
| Endurance at 100% CPU | System remains stable; input behavior is improved |

The exact result depends on the workload.

## Automatic Fix

Run:

```bash
chmod +x install_synergy_qos_fix_auto.sh
./install_synergy_qos_fix_auto.sh
```

The installer:

1. Backs up the original Synergy LaunchAgent.
2. Adds `ProcessType=Interactive`.
3. Creates a small `launchd` watcher.
4. Restarts Synergy.
5. Automatically restores `ProcessType=Interactive` if Synergy rewrites its plist.

The watcher uses `WatchPaths`, so it does **not** continuously poll the file.

## Uninstall

Run:

```bash
chmod +x uninstall_synergy_qos_fix.sh
./uninstall_synergy_qos_fix.sh
```

The uninstaller removes the watcher and restores the original Synergy LaunchAgent.

## Limitations

This is an **unofficial community workaround**, not an official Symless fix.

The workaround changes the observed QoS from `Utility` to `Default`. It does not provide `User Initiated` or `User Interactive` QoS, and some input lag may remain under extreme CPU contention.

## Tested Environment

- Apple Silicon MacBook Air
- macOS Sequoia / Tahoe
- Synergy 3
- Windows client on the same LAN

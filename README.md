# Synergy 3 macOS: fixing input lag under high CPU load (QoS fix)

## Problem

When the macOS host running **Synergy 3** (server side) is under heavy CPU load
(close to 0% idle across all cores), keyboard/mouse input relayed to the Windows
client via Synergy becomes laggy or unresponsive. As soon as the CPU load drops,
Synergy responsiveness returns to normal almost immediately.

- **Environment:** MacBook Air (Apple Silicon), macOS Sequoia/Tahoe, Synergy 3
  v3.6.3 (bundles Synergy Core 1.20.1), Windows client on the same LAN.
- **Reproducible with any CPU-saturating workload** — not specific to any one
  app. Confirmed with both Chrome (heavy tab load) and
  [Endurance](https://apphousekitchen.com/) stress test app.
- Lag correlates with **CPU saturation** (~0% idle), not simply "high" CPU
  (85–90% CPU utilization on 6 cores showed no lag; 100% utilization did).

## What was ruled out

Systematically tested and eliminated, in order:

| Hypothesis | Result |
|---|---|
| App Nap | Not the cause (`App Nap: No` in Activity Monitor) |
| `renice` on `synergy-core` / `synergy-service` | No effect |
| TLS | Already disabled, not the cause |
| AWDL (`ifconfig awdl0 down`) | No effect |
| Network latency spike (ICMP ping under load) | Not observed (3–6 ms, no spikes/timeouts) |
| Chrome specifically | Not the cause — any CPU stress reproduces it |
| High CPU alone (85–90%) | Not sufficient on its own |
| **Full CPU saturation (~0% idle)** | **Strong correlation** |

## Root cause

Using `sudo powermetrics --show-process-qos --samplers tasks`, the actual
scheduling **Quality of Service (QoS)** class of the running processes was
inspected. Result:

```
synergy-core     <PID>   ...   QoS: Utility
synergy-service  <PID>   ...   QoS: Utility
```

`synergy-core` — the process responsible for relaying keyboard/mouse events —
starts at **QoS "Utility"**, the class macOS reserves for background work the
user isn't actively tracking. This is inconsistent with what the process
actually does (low-latency, user-facing input handling), and under full CPU
saturation macOS deprioritizes Utility-class threads in favor of higher-QoS
work, causing the observed lag.

Two external mechanisms were tested and confirmed **ineffective** at raising
this QoS from outside the process:

- `taskpolicy -B -p <pid>` — macOS's `taskpolicy` can only **demote** a
  process's QoS (confine it to efficiency cores), it cannot **promote** a
  process that itself requested a low QoS at startup. Confirmed by testing:
  no change in `powermetrics` output before/after.
- Simple `nice`/renice — affects traditional Unix scheduling priority, not the
  separate QoS mechanism macOS actually uses for core/thread scheduling
  decisions on Apple Silicon.

## The fix (partial, but effective)

Synergy 3 on macOS is launched via a per-user LaunchAgent:

```
~/Library/LaunchAgents/com.symless.synergy3.plist
```

This plist had no `ProcessType` key set, so it defaulted to macOS's standard
background-ish scheduling treatment. Adding:

```xml
<key>ProcessType</key>
<string>Interactive</string>
```

and reloading the LaunchAgent **raises the process's QoS from `Utility` to
`Default`** — one tier up in macOS's scheduling hierarchy
(Background < Utility < Default < User Initiated < User Interactive).

This is **not** the maximum possible QoS (`User Interactive`), and
`synergy-core` appears to override/reset its own QoS internally at some point
(a subsequent `taskpolicy -B` attempt after this fix showed no further
increase), so this is a ceiling reachable without modifying the (closed-source)
Synergy 3 binary itself.

### Measured result

| Load condition | Before fix | After fix |
|---|---|---|
| 6 cores @ 85–95% CPU | Slight lag | **No lag** |
| Full CPU saturation (~100%, 0% idle) | Noticeable lag | Minor residual lag |

## How to apply

Run [`fix_synergy_qos.sh`](./fix_synergy_qos.sh):

```bash
chmod +x fix_synergy_qos.sh
./fix_synergy_qos.sh
```

The script:
1. Snapshots the current QoS of `synergy-core` (before/after comparison).
2. Backs up the LaunchAgent plist.
3. Adds/updates `ProcessType: Interactive` in the plist.
4. Cleanly kills any stray/orphaned Synergy processes (a known side effect of
   `launchctl unload/load` not always cleaning up child processes).
5. Restarts the service via the modern `launchctl bootstrap` API.
6. Prompts you to generate some input load, then re-checks QoS to confirm the
   change took effect.

### Rollback

```bash
cp ~/Library/LaunchAgents/com.symless.synergy3.plist.bak \
   ~/Library/LaunchAgents/com.symless.synergy3.plist
launchctl bootout gui/$(id -u)/com.symless.synergy3
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.symless.synergy3.plist
```

## Notes / open questions

- This works around the issue at the launchd level; it does not fix the root
  cause, which is that `synergy-core` requests `Utility` QoS for itself in its
  own (closed-source, in Synergy 3) code. A proper fix would need to come from
  Symless, or from switching to the open-source
  [deskflow](https://github.com/deskflow/deskflow) fork, where this could
  potentially be patched directly.
- If anyone tests this on Intel Macs or other macOS versions, results/feedback
  welcome via issues.

## Disclaimer

This is a community workaround based on empirical testing, not an official
fix from Symless. Tested only on Apple Silicon / macOS Sequoia-Tahoe with
Synergy 3 v3.6.3. Use at your own risk; back up your LaunchAgent plist first
(the script does this automatically).

# `simctl` command reference (depth)

Full subcommand catalog and scripting patterns. `xcrun simctl help` and
`xcrun simctl help <subcommand>` print the authoritative option list for the
installed Xcode — this file is the curated fintech/CI subset.

## Global options

- `--set <path>` — operate on a private device set (isolate CI from the developer's default set). Applies to nearly every subcommand.
- `-j` / `--json` on `list` — machine-readable output; the only safe input for scripts.

## Selecting devices

```bash
xcrun simctl list                     # devices + runtimes + devicetypes + pairs
xcrun simctl list devices available    # only devices on installed runtimes
xcrun simctl list runtimes -j          # runtime identifiers for `create`
xcrun simctl list devicetypes -j       # devicetype identifiers for `create`
```

Resolve helpers:

```bash
# Newest available iPhone 16 Pro UDID:
xcrun simctl list devices -j | jq -r \
  '[.devices[][] | select(.name=="iPhone 16 Pro" and .isAvailable)][0].udid'

# All booted UDIDs:
xcrun simctl list devices -j | jq -r '.devices[][] | select(.state=="Booted").udid'
```

## Lifecycle

| Command | Notes |
|---|---|
| `create <name> <devicetype> [<runtime>]` | prints the new UDID to stdout |
| `clone <device> <new name>` | duplicate a fully-configured device |
| `boot <device>` | headless; errors if already booted |
| `bootstatus <device> [-b]` | `-b` blocks until boot completes, then exits |
| `shutdown <device>` / `shutdown all` | |
| `erase <device>` / `erase all` | device(s) must be shut down first |
| `delete <device>` / `delete unavailable` / `delete all` | frees disk in `~/Library/Developer/CoreSimulator/Devices` |
| `upgrade <device> <runtime>` | move an existing device to a newer runtime |
| `rename <device> <name>` | |

Reliable CI boot:

```bash
xcrun simctl boot "$UDID" 2>/dev/null || true   # tolerate already-booted
xcrun simctl bootstatus "$UDID" -b               # wait until actually ready
```

## Apps

| Command | Notes |
|---|---|
| `install <device> <path.app>` | Simulator-SDK build only |
| `launch [--console] [--wait-for-debugger] <device> <bundle id> [args…]` | args become the process's `argv`; `--console` mirrors stdout/stderr |
| `terminate <device> <bundle id>` | |
| `uninstall <device> <bundle id>` | removes app + its data container |
| `get_app_container <device> <bundle id> [app\|data\|groups\|<group id>]` | |
| `spawn <device> <executable> [args…]` | run a binary inside the sim (e.g. `log`) |

Environment injection: any `SIMCTL_CHILD_<NAME>` variable in the calling shell is
passed to the launched app as `<NAME>`.

```bash
SIMCTL_CHILD_API_BASE_URL="https://sandbox.example.com" \
  xcrun simctl launch --console booted com.example.myapp -resetOnboarding YES
```

## Notifications

```bash
xcrun simctl push <device> [<bundle id>] (<payload.json> | -)
```

- Payload: top-level object, valid `aps`, ≤ 4096 bytes. `"Simulator Target Bundle"` key can replace the CLI bundle id.
- Rich pushes: include `mutable-content: 1` and your keys; the Notification Service Extension runs as on device.
- Not supported: VoIP/PushKit, Complication, File Provider.

## URLs

```bash
xcrun simctl openurl <device> <url>
```

- Custom scheme → app declaring it. `https` → Universal Link app (if AASA + entitlement resolve) else Safari. `tel:`/`mailto:`/`maps:` → system handlers.

## Privacy (TCC)

```bash
xcrun simctl privacy <device> (grant|revoke|reset) <service> [<bundle id>]
```

Services: `all`, `calendar`, `contacts-limited`, `contacts`, `location`,
`location-always`, `photos-add`, `photos`, `media-library`, `microphone`,
`motion`, `reminders`, `siri`, `camera`. (`camera` is accepted although omitted
from the `simctl privacy` help; `faceid`, `speech-recognition`, and
`user-tracking` are **not** valid services — `simctl privacy` rejects them. Run
`xcrun simctl privacy` with no args for the authoritative list.)

## Location

```bash
xcrun simctl location <device> set <lat>,<long>
xcrun simctl location <device> list
xcrun simctl location <device> run <scenario name>
xcrun simctl location <device> start [--speed=<mps>] [--distance=<m>] [--interval=<s>] <lat,long> [<lat,long> …]
xcrun simctl location <device> clear
```

## Status bar

```bash
xcrun simctl status_bar <device> override [flags]
xcrun simctl status_bar <device> clear
```

Flags: `--time`, `--dataNetwork {hide|wifi|3g|4g|lte|lte-a|lte+|5g|5g+|5g-uwb|5g-uc}`,
`--wifiMode {searching|failed|active}`, `--wifiBars {0..3}`,
`--cellularMode {notSupported|searching|failed|active}`, `--cellularBars {0..4}`,
`--operatorName`, `--batteryState {charging|charged|discharging}`,
`--batteryLevel {0..100}`. Overrides reset on shutdown.

## IO

```bash
xcrun simctl io <device> screenshot [--type=png|jpeg] [--display=internal|external] [--mask=ignored|alpha|black] <file>
xcrun simctl io <device> recordVideo [--codec=hevc|h264] [--display=…] [--mask=…] [--force] <file>
xcrun simctl io <device> enumerate            # available displays/ports
```

## Diagnostics & keychain

```bash
xcrun simctl spawn <device> log stream --level {default|info|debug} --predicate '<NSPredicate>'
xcrun simctl spawn <device> log show --last <duration> --predicate '<NSPredicate>'
xcrun simctl addmedia <device> <file> [<file> …]
xcrun simctl keychain <device> add-root-cert <cert.pem|.cer>
xcrun simctl keychain <device> add-cert <cert>
xcrun simctl keychain <device> reset
xcrun simctl diagnose                          # collect a full CoreSimulator diagnostic bundle
```

## Recovery

```bash
xcrun simctl shutdown all
xcrun simctl erase all            # wipe every device (all must be shut down)
sudo killall -9 com.apple.CoreSimulator.CoreSimulatorService   # restart the sim service if wedged
```

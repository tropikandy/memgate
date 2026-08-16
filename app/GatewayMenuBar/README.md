# Gateway (menu bar app)

A small native macOS menu bar utility for the Local Model Gateway. Not
part of the gateway's v1 spec (that explicitly lists a custom UI as a
non-goal, Section 1.2) — this is a separate, optional convenience layer
that talks to the already-running gateway and memwarden over plain HTTP,
same as anything else would.

## What it does

The menu bar icon signals state at a glance via **shape**, not color
(status items render as monochrome template images that auto-adapt to
light/dark menu bars — using `.foregroundStyle`/`.symbolRenderingMode`
breaks that, found the hard way while building this, see the comment in
`ContentViews.swift`):

| Icon | Meaning |
|---|---|
| `?` in a circle | Gateway unreachable |
| dotted circle | Idle, no model resident |
| filled circle | Serving the 4B tier |
| filled square | Serving the 27B tier |
| pause circle | Paused (yield lock held) |
| warning triangle | Critical ladder level (4) |

Clicking it opens a dropdown with live status (polls `:8000/v1/models`
and `:8011/state` every 5s) and two actions:

- **Pause / resume model loading** — calls memwarden's `/yield` and
  `/release` (IF-6). This is exactly R17's mechanism; the app is just a
  client of it, no special integration.
- **Restart Gateway Infrastructure** — `launchctl kickstart -k` on
  `com.local.llama-swap` and `com.local.memwarden`. Requires those
  LaunchAgents to already be installed (WP-008/WP-014); this app doesn't
  install them.

## Build and install

Requires Xcode command line tools (`swift`, `swiftc` — already present
if you can build the rest of this project). No other dependencies.

```
cd app/GatewayMenuBar
./install.sh          # builds if needed, installs to /Applications,
                       # sets up a login LaunchAgent
./install.sh --rebuild # force a rebuild first
```

Or just build without installing:

```
./build.sh             # produces Gateway.app in this directory
open Gateway.app        # run it once, not installed
```

Ad-hoc code signed (no Apple Developer account needed) — fine for
running on this machine, not for distribution to others.

### Regenerating the icon

`make_icon.swift` renders `AppIcon.icns` from scratch (a simple
Core Graphics gradient + shape composition, no external assets):

```
swift make_icon.swift /tmp/icon-1024.png
# then re-run the iconset/iconutil steps, or just re-run build.sh
# after replacing AppIcon.icns
```

### Uninstall

```
launchctl bootout gui/$(id -u)/com.local.gateway-menubar
rm ~/Library/LaunchAgents/com.local.gateway-menubar.plist
rm -rf /Applications/Gateway.app
```

## Known limitations

- Assumes the gateway is on `127.0.0.1:8000` and memwarden on
  `127.0.0.1:8011` — not configurable yet (would be a small addition,
  a `UserDefaults`-backed settings sheet, not done here).
- No notification/alert on ladder level 4 (critical) beyond the icon
  changing — R19 says level 4 events should be "logged loudly"; this
  app doesn't add its own alerting on top of memwarden's own event log.
- Single-machine, single-user tool. Not sandboxed, not notarized, not
  meant to leave this machine.

# Changelog

All notable changes to Fivebars. Versions follow [semantic versioning](https://semver.org).
Downloads: https://callingcodes.com/fivebars/download/latest

## 1.1.0 (2026-10-24)

- A new menu: Fivebars opens a single native menu from the menu bar, translucent like the
  system's own, on left or right click. The separate right-click menu is gone.
- Clearer chart: the 5-minute chart uses wider bars, each coloured by its worst moment (green,
  orange when slow, red when lost).
- Choose how often to ping: any interval from 1 to 60 seconds in Settings. The quality score
  adapts so the bars stay meaningful at slow intervals.
- Packet loss, only when it matters: Off, When There's Loss or Always. When There's Loss is the
  new default; an existing on/off setting carries over as Always/Off.
- Tighter menu bar item: less empty space next to the packet loss percentage.
- Closes like a menu: click anywhere else or press Esc.

## 1.0.0 (2026-10-24)

- New app icon and a designed installer window.
- Pings of 100 ms and over show in seconds (0.4s), so the menu bar item keeps one fixed width.
- Tighter menu bar spacing that matches the system's own items.
- Check for Updates… and update settings.
- Signed with Developer ID and notarized by Apple.

## 0.9.0 (2026-10-24)

- First public beta: connection quality in the menu bar as five signal bars and the latest
  ping time, a 5-minute latency chart, session and all-time statistics, optional up/down
  alerts, recovery after sleep, network changes and DNS failures, unprivileged ICMP (no root,
  no helper), and daily update checks through Sparkle.

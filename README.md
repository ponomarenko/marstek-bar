# MarstekBar

A tiny macOS menu bar app that shows the state of a Marstek Venus E 3.0 battery
using the Marstek Local Open API (JSON over UDP, port 30000). No cloud involved.

## Requirements

- macOS 13+
- Swift toolchain (Xcode Command Line Tools are enough)
- Open API enabled on the battery (Marstek app → device settings), port 30000
- The Mac and the battery on the same LAN

## Build and run

```sh
./scripts/build-app.sh
open build/MarstekBar.app
```

On first launch macOS asks for Local Network access — allow it.

## How it works

- The battery is discovered with a `Marstek.GetDevice` UDP broadcast; its IP is cached
  and re-discovered automatically after three failed polls.
- Every 60 seconds the app sends `ES.GetMode` and `Bat.GetStatus`, one second apart.
  The device API is fragile, so the polling is deliberately gentle.
- If no fresh data arrives for 3 minutes the icon switches to a warning sign and the
  last known value stays visible.

## Notes

- The UI is in English or Ukrainian, following the system language. Translations live
  in `Resources/uk.lproj`; English strings are the keys used in the code.
- Net battery power is computed as `ongrid_power + offgrid_power`, assuming positive
  values mean discharge. Verify the sign while the battery is charging.
- History is kept in memory only (last 24 hours).

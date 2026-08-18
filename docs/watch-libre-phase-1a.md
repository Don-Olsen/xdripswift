# Apple Watch Libre diagnostic — Phase 1A

## Purpose

Phase 1A determines whether Apple Watch can passively observe an advertisement for Bluetooth service `FDE3`, which the current xDrip Libre 2 implementation also identifies as the Libre 2 service. An observation is reported only as an **FDE3 candidate**; it does not establish sensor compatibility.

## Safety boundaries

This diagnostic uses a dedicated, foreground-only CoreBluetooth scanner. It:

- starts only after the user presses **Start scanning**;
- scans only for `FDE3` advertisements;
- stops on request, after five minutes, or when the diagnostic view disappears;
- keeps observations in memory only;
- converts a peripheral identifier immediately into a short, scan-specific redacted label;
- does not collect or display glucose data.

Phase 1A has no sensor connection, service or characteristic discovery, notification subscription, characteristic write, unlock command, pairing change, NFC operation, alarm, or treatment recommendation. It does not reuse the existing Libre collector implementation.

## Files

- `xDrip Watch App/DataModels/LibreWatchDiagnosticState.swift` — side-effect-free state, aggregation, timeout, and identifier redaction.
- `xDrip Watch App/DataModels/LibreWatchPassiveScanner.swift` — passive `FDE3` CoreBluetooth scan.
- `xDrip Watch App/Views/DirectSensorTestView.swift` — the Watch diagnostic screen.
- `Tests/WatchLibreDiagnosticTests.swift` — deterministic model tests.
- `Tests/check_watch_libre_phase1a_safety.sh` and `.ps1` — source-level safety guards for CI/macOS and Windows.

## Open the diagnostic

Open xDrip on Apple Watch. From the normal glucose screen, swipe horizontally through the existing carousel until **Direct Sensor Test** appears. The existing glucose screens remain the first two pages.

## First physical test

1. Keep the normal glucose application and collector running as usual.
2. Wear the Apple Watch and remain near the active Libre 2 or Libre 2 Plus sensor.
3. Open xDrip on the Watch and swipe to **Direct Sensor Test**.
4. Confirm that Bluetooth shows **On** and the warning **Diagnostic only — no glucose data** is visible.
5. Press **Start scanning** once.
6. Leave the diagnostic visible for the full five minutes. Do not change or stop the normal glucose application.
7. Note the final result, observation count, last RSSI, last-seen time, and redacted candidate label.
8. The scan stops automatically at `5:00`. It can also be stopped manually; leaving the screen stops it immediately.

## Interpret the result

**FDE3 candidate observed** means the Watch received at least one advertisement matching the `FDE3` scan filter. It is useful evidence for the next diagnostic phase, but it does not prove that the device is a compatible Libre sensor.

**No candidate observed during this scan** means that no matching advertisement reached the Watch during this particular interval. It does not mean that the sensor or Watch is unsupported; advertising timing, radio conditions, distance, and another collector may affect observation.

## Planned Phase 1B

Phase 1B may add an explicit, foreground-only candidate connection and service/characteristic discovery, still with no writes. It is intentionally not implemented in this build and requires a separate safety review.

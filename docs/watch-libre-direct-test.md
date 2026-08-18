# Libre 2 Plus → Apple Watch direct hardware test

## Purpose and scope

This internal TestFlight experiment tests a European Libre 2 Plus (`C6` or `7F`) directly from Apple Watch while the **Direct Sensor Test** screen stays open. It deliberately does not implement background collection, alarms, HealthKit, Nightscout, complications, treatment recommendations, or automatic phone/Watch hand-off.

Only an expendable test sensor may be prepared. A separate live CGM sensor must not be NFC-scanned in this TestFlight copy.

## Proven xDrip logic reused

- The existing `LibreNFC` flow supplies sensor UID, patch info, serial, type, streaming enable result, and the NFC-derived BLE identity.
- `Libre2BLEUtilities.streamingUnlockPayload` and `decryptBLE` now call the same shared `Libre2DirectAlgorithms` implementation compiled for both iOS and watchOS.
- The 46-byte framing, CRC, raw glucose/temperature bit positions, NFC-derived calibration parameters, scaling, and unlock counter semantics come from the current iPhone Libre 2 collector.
- The iPhone collector retains its stored identity but pauses scan/reconnect while Watch owns this exact session.

No physical Watch-to-sensor success is claimed by the build or deterministic tests.

## Prepare the expendable sensor on iPhone

1. Start the expendable Danish/European Libre 2 Plus correctly. If LibreLink is required for activation, use it; xDrip does not reinvent activation.
2. Complete the sensor warm-up.
3. Disable LibreLink's Bluetooth access so it does not retain the test sensor connection.
4. In this TestFlight xDrip app, open the configured **Libre 2/2+ EU** peripheral settings.
5. Tap **Prepare Libre 2 Plus Watch Test** and accept the warning.
6. NFC-scan the expendable test sensor using the normal xDrip NFC flow.
7. Wait for the confirmation that the Watch test session was prepared.

The prepared, versioned Watch session is rejected unless all required values validate and the sensor is specifically type `C6` or `7F`. For `C6`, identity is `ABBOTT` plus the NFC serial; for `7F`, it is the NFC-returned BLE MAC identity. Watch never selects an arbitrary `FDE3` candidate.

## Run the five-minute physical test

1. Keep iPhone and Apple Watch reachable to each other.
2. Open xDrip on Apple Watch and swipe to the third carousel page, **Direct Sensor Test**.
3. Confirm the screen shows **READY**, a redacted test-sensor identity, and ownership `iphone`.
4. Keep this screen visible and tap **Start Direct Test** once.
5. Watch the expected progression: **RELEASING TO WATCH → SCANNING → IDENTITY MATCHED → CONNECTING → CONNECTED → FDE3 FOUND → F001 + F002 FOUND → NOTIFICATIONS ACTIVE → UNLOCK SENT → PACKET RECEIVED → FRAME COMPLETE → DECRYPTED → GLUCOSE DECODED**.
6. Success is shown only as **DIRECT FROM SENSOR** with glucose, unit, trend when available, and the last direct packet time.
7. Tap **Stop Direct Test / Return Control**, or leave the screen. Scanning/connection stops and iPhone ownership is restored. The test also ends automatically after five minutes.

If it fails, record the exact last uppercase stage/error, the compact CoreBluetooth detail, fragment count, byte count, and complete-frame count. Absence of a matching advertisement during one test does not prove incompatibility.

## Direct-source guarantee

The direct reading model has explicit provenance. Only a frame received by the Watch `CBPeripheralDelegate` from `F002`, assembled to 46 bytes, CRC-verified, decrypted, and parsed may set source `watchSensorF002` and display **DIRECT FROM SENSOR**. Normal glucose received from iPhone through `WatchConnectivity` uses a separate data path and cannot set that label.

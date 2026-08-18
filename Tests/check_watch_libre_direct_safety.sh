#!/usr/bin/env bash
set -euo pipefail

collector="xDrip Watch App/DataModels/LibreWatchDirectCollector.swift"
state="xDrip Watch App/DataModels/LibreWatchDirectState.swift"
session="xDrip/Managers/Watch/LibreWatchTestSession.swift"
algorithms="xDrip/BluetoothTransmitter/CGM/Libre/Utilities/Libre2DirectAlgorithms.swift"
view="xDrip Watch App/Views/DirectSensorTestView.swift"

for file in "$collector" "$state" "$session" "$algorithms" "$view"; do
  test -f "$file"
done

test "$(grep -Ec 'central\.connect\(' "$collector")" -eq 1
test "$(grep -Ec 'peripheral\.writeValue\(' "$collector")" -eq 1

grep -Fq 'identityAndOwnershipAreConfirmed(for: peripheral)' "$collector"
grep -Fq 'watchState?.libreWatchTestOwnership == .watch' "$collector"
grep -Fq 'preparedSession.matches(candidateName: matchedPeripheralName)' "$collector"
grep -Fq 'withServices: [CBUUID(string: Libre2DirectConstants.serviceUUIDString)]' "$collector"
grep -Fq 'source == .watchSensorF002' "$algorithms"
grep -Fq 'guard reading.source == .watchSensorF002' "$state"
grep -Fq 'DIRECT FROM SENSOR' "$view"
grep -Fq 'Experimental test sensor only — do not use for treatment decisions.' "$view"

if grep -En 'bgReadingValues|processWatchStateFromDictionary|iphoneWatchConnectivity.*DIRECT FROM SENSOR' "$collector" "$state" "$view"; then
  echo "Direct-source safety failure: normal WatchConnectivity glucose entered the direct-test path." >&2
  exit 1
fi

if grep -En 'private.*entitlement|com\.apple\.developer\..*extended|HKWorkoutSession|WKExtendedRuntimeSession|AVAudioSession|CLLocationManager' "$collector" "$state" "$view"; then
  echo "Foreground-only safety failure: background/private capability token found." >&2
  exit 1
fi

grep -Fq 'xdrip.xcworkspace' codemagic.yaml
echo "Watch Libre direct-test safety checks passed"

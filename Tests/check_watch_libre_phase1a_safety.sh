#!/usr/bin/env bash
set -euo pipefail

watch_files=(
  "xDrip Watch App/DataModels/LibreWatchDiagnosticState.swift"
  "xDrip Watch App/DataModels/LibreWatchPassiveScanner.swift"
)

for file in "${watch_files[@]}"; do
  test -f "$file"
done

forbidden_pattern='connect[[:space:]]*\(|discoverServices|discoverCharacteristics|writeValue|setNotifyValue|F001|F002|unlock|NFC|CBPeripheralDelegate|cancelPeripheralConnection|print[[:space:]]*\(|os_log|Logger[[:space:]]*\('

if grep -En "$forbidden_pattern" "${watch_files[@]}"; then
  echo "Phase 1A safety failure: an active sensor path or unsafe logging token was found." >&2
  exit 1
fi

grep -Fq 'withServices: [CBUUID(string: LibreWatchDiagnosticState.serviceUUIDString)]' \
  "xDrip Watch App/DataModels/LibreWatchPassiveScanner.swift"
grep -Fq 'static let serviceUUIDString = "FDE3"' \
  "xDrip Watch App/DataModels/LibreWatchDiagnosticState.swift"
grep -Fq 'WatchStateModel.swift in Sources' xdrip.xcodeproj/project.pbxproj
grep -Fq 'NSBluetoothAlwaysUsageDescription' xDrip-Watch-App-Info.plist

echo "Watch Libre Phase 1A passive-scanner isolation checks passed"

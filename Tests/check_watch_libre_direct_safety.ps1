$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

$collector = "xDrip Watch App/DataModels/LibreWatchDirectCollector.swift"
$state = "xDrip Watch App/DataModels/LibreWatchDirectState.swift"
$session = "xDrip/Managers/Watch/LibreWatchTestSession.swift"
$algorithms = "xDrip/BluetoothTransmitter/CGM/Libre/Utilities/Libre2DirectAlgorithms.swift"
$view = "xDrip Watch App/Views/DirectSensorTestView.swift"
$phoneBluetoothTransmitter = "xDrip/BluetoothTransmitter/Generic/BluetoothTransmitter.swift"

foreach ($file in @($collector, $state, $session, $algorithms, $view, $phoneBluetoothTransmitter)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing direct-test file: $file"
    }
}

function Assert-FileContains {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Text
    )
    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Contains($Text)) {
        throw "Expected text was not found in ${Path}: $Text"
    }
}

$collectorSource = Get-Content -LiteralPath $collector -Raw
if ([regex]::Matches($collectorSource, 'central\.connect\(').Count -ne 1) {
    throw "Expected exactly one guarded Watch peripheral connection path."
}
if ([regex]::Matches($collectorSource, 'peripheral\.writeValue\(').Count -ne 1) {
    throw "Expected exactly one guarded Watch characteristic write path."
}

Assert-FileContains -Path $collector -Text 'identityAndOwnershipAreConfirmed(for: peripheral)'
Assert-FileContains -Path $collector -Text 'watchState?.libreWatchTestOwnership == .watch'
Assert-FileContains -Path $collector -Text 'preparedSession.matches(candidateName: matchedPeripheralName)'
Assert-FileContains -Path $collector -Text 'withServices: [CBUUID(string: Libre2DirectConstants.serviceUUIDString)]'
Assert-FileContains -Path $algorithms -Text 'source == .watchSensorF002'
Assert-FileContains -Path $state -Text 'guard reading.source == .watchSensorF002'
Assert-FileContains -Path $view -Text 'DIRECT FROM SENSOR'
Assert-FileContains -Path $view -Text 'Experimental test sensor only — do not use for treatment decisions.'
Assert-FileContains -Path "codemagic.yaml" -Text 'xdrip.xcworkspace'

$phoneBluetoothSource = Get-Content -LiteralPath $phoneBluetoothTransmitter -Raw
if ($phoneBluetoothSource -notmatch '(?s)func connect\(\) \{.*?guard !self\.isTemporarilyPaused else \{ return \}') {
    throw "Phone reconnect is not suppressed during Watch ownership."
}
if ($phoneBluetoothSource -notmatch '(?s)fileprivate func stopScanAndconnect\(to peripheral: CBPeripheral\) \{.*?guard !isTemporarilyPaused else \{ return \}') {
    throw "A queued phone discovery can reconnect during Watch ownership."
}
if ($phoneBluetoothSource -notmatch '(?s)func pauseConnectionWithoutReconnect\(completion: @escaping \(\) -> Void\) \{.*?self\.cancelConnectionTimer\(\)') {
    throw "A pending phone connection timer can reconnect during Watch ownership."
}
if ($phoneBluetoothSource -notmatch '(?s)func resumeConnectionAfterTemporaryPause\(\) \{.*?self\.isTemporarilyPaused = false') {
    throw "Phone reconnect suppression is not released on return control."
}

$directSources = (Get-Content -LiteralPath $collector, $state, $view -Raw) -join "`n"
if ($directSources -match 'bgReadingValues|processWatchStateFromDictionary|iphoneWatchConnectivity.*DIRECT FROM SENSOR') {
    throw "Direct-source safety failure: normal WatchConnectivity glucose entered the direct-test path."
}
if ($directSources -match 'private.*entitlement|com\.apple\.developer\..*extended|HKWorkoutSession|WKExtendedRuntimeSession|AVAudioSession|CLLocationManager') {
    throw "Foreground-only safety failure: background/private capability token found."
}

Write-Host "Watch Libre direct-test safety checks passed"

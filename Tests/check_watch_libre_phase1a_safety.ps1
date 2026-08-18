$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

$watchFiles = @(
    "xDrip Watch App/DataModels/LibreWatchDiagnosticState.swift",
    "xDrip Watch App/DataModels/LibreWatchPassiveScanner.swift",
    "xDrip Watch App/Views/DirectSensorTestView.swift"
)

foreach ($file in $watchFiles) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Missing Phase 1A file: $file"
    }
}

$watchSource = ($watchFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$forbiddenPattern = 'connect\s*\(|discoverServices|discoverCharacteristics|writeValue|setNotifyValue|F001|F002|unlock|NFC|CBPeripheralDelegate|cancelPeripheralConnection|print\s*\(|os_log|Logger\s*\('

if ($watchSource -match $forbiddenPattern) {
    throw "Phase 1A safety failure: an active sensor path or unsafe logging token was found: $($Matches[0])"
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

Assert-FileContains `
    -Path "xDrip Watch App/DataModels/LibreWatchPassiveScanner.swift" `
    -Text 'withServices: [CBUUID(string: LibreWatchDiagnosticState.serviceUUIDString)]'
Assert-FileContains `
    -Path "xDrip Watch App/DataModels/LibreWatchDiagnosticState.swift" `
    -Text 'static let serviceUUIDString = "FDE3"'
Assert-FileContains `
    -Path "xDrip Watch App/Views/DirectSensorTestView.swift" `
    -Text 'scanner.viewDidDisappear()'
Assert-FileContains `
    -Path "xDrip Watch App/Views/DirectSensorTestView.swift" `
    -Text 'Diagnostic only — no glucose data'
Assert-FileContains `
    -Path "xdrip.xcodeproj/project.pbxproj" `
    -Text 'WatchStateModel.swift in Sources'
Assert-FileContains `
    -Path "xDrip-Watch-App-Info.plist" `
    -Text 'NSBluetoothAlwaysUsageDescription'

Write-Host "Watch Libre Phase 1A safety checks passed"

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutter = 'C:\App\Flutter\bin\flutter.bat'
$adb = 'adb'
$apkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'

if (-not (Test-Path $flutter)) {
    throw "Flutter was not found at $flutter"
}

Write-Host 'Building arm64 release APK for local device testing...'
& $flutter build apk --release --target-platform android-arm64
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if (-not (Test-Path $apkPath)) {
    throw "Expected APK was not found at $apkPath"
}

Write-Host "Installing $apkPath ..."
& $adb install -r $apkPath
exit $LASTEXITCODE

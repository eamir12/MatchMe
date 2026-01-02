#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Write-Host "Pre-commit: running dart fixes and flutter analyze"

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
  Write-Error "'dart' not found in PATH. Install Dart SDK and ensure 'dart' is available."
  exit 1
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error "'flutter' not found in PATH. Install Flutter and ensure 'flutter' is available."
  exit 1
}

Write-Host "Running: dart fix --apply"
dart fix --apply

# Re-stage any changes made by dart fix
git add -A

Write-Host "Running: flutter analyze"
$result = flutter analyze
if ($LASTEXITCODE -ne 0) {
  Write-Error "flutter analyze failed — please fix analyzer errors before committing."
  exit $LASTEXITCODE
}

Write-Host "Pre-commit checks passed."
exit 0

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$flutterArgs = @(
    'run',
    '--no-enable-dart-profiling',
    '--dart-define=flutter.flutter_map.unblockOSM=Our tile servers are not.'
) + $args

Write-Host 'Starting MatchMe mobile debug run...' -ForegroundColor Cyan
& flutter @flutterArgs
exit $LASTEXITCODE

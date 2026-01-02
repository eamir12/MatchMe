# Download Noto Symbols fonts used by the app into assets/fonts/
# Usage: Open PowerShell in the repo root and run: .\tools\download_noto_symbols.ps1

$fonts = @(
  @{name='NotoSansSymbols-Regular.ttf'; urls=@(
      'https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansSymbols/NotoSansSymbols-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSansSymbols/NotoSansSymbols-Regular.ttf'
    )},
  @{name='NotoSansSymbols2-Regular.ttf'; urls=@(
      'https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansSymbols2/NotoSansSymbols2-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSansSymbols2/NotoSansSymbols2-Regular.ttf'
    )}
)

$dest = "assets/fonts"
if (!(Test-Path $dest)) {
  New-Item -ItemType Directory -Path $dest | Out-Null
}

$failures = @()
foreach ($f in $fonts) {
  $downloaded = $false
  foreach ($u in $f.urls) {
    $out = Join-Path $dest $f.name
    try {
      Write-Host "Trying $u ..."
      Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
      Write-Host "  -> saved to $out"
      $downloaded = $true
      break
    } catch {
      $msg = $_.Exception.Message
      Write-Warning "Failed to download $($f.name) from ${u} - $msg"
    }
  }
  if (-not $downloaded) { $failures += @{name=$f.name; tried=$f.urls} }
}

if ($failures.Count -gt 0) {
  Write-Host "\nSome symbol fonts failed to download. Please fetch them manually from Google Fonts or the Noto repos and place them into assets/fonts/." -ForegroundColor Yellow
  foreach ($f in $failures) {
    Write-Host " - $($f.name) (tried: $($f.tried -join ', '))"
  }
  Write-Host "\nAfter copying, run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
} else {
  Write-Host "\nAll symbol fonts downloaded successfully." -ForegroundColor Green
  Write-Host "Run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
}
# Attempt to download NotoSansTC-Bold from alternative sources into assets/fonts/
# Usage: powershell -ExecutionPolicy Bypass -File .\tools\download_noto_tc_bold.ps1

$dest = "assets/fonts"
if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

$candidates = @(
  @{url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansTC/NotoSansTC-Bold.ttf'; name='NotoSansTC-Bold.ttf'},
  @{url='https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSansTC/NotoSansTC-Bold.ttf'; name='NotoSansTC-Bold.ttf'},
  @{url='https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTF/NotoSansTC-Bold.otf'; name='NotoSansTC-Bold.otf'},
  @{url='https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/OTF/NotoSansTC-Bold.otf'; name='NotoSansTC-Bold.otf'},
  @{url='https://github.com/googlefonts/noto-cjk/raw/main/Sans/TTF/NotoSansTC-Bold.ttf'; name='NotoSansTC-Bold.ttf'},
  @{url='https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/TTF/NotoSansTC-Bold.ttf'; name='NotoSansTC-Bold.ttf'},
  @{url='https://github.com/googlefonts/noto-cjk/raw/main/unhinted/otf/NotoSansTC-Bold.otf'; name='NotoSansTC-Bold.otf'},
  @{url='https://raw.githubusercontent.com/googlefonts/noto-cjk/main/unhinted/otf/NotoSansTC-Bold.otf'; name='NotoSansTC-Bold.otf'}
)

$downloaded = $false
foreach ($c in $candidates) {
  $out = Join-Path $dest $c.name
  try {
    Write-Host "Trying $($c.url) ..."
    Invoke-WebRequest -Uri $c.url -OutFile $out -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    Write-Host "  -> saved $out"
    $downloaded = $true
    break
  } catch {
    Write-Warning "Failed: $($_.Exception.Message)"
  }
}

if (-not $downloaded) {
  Write-Host "Could not download NotoSansTC-Bold from alternate sources. Please fetch manually from one of the URLs below and place it in assets/fonts/:" -ForegroundColor Yellow
  foreach ($c in $candidates) { Write-Host " - $($c.name): $($c.url)" }
} else {
  Write-Host "NotoSansTC-Bold downloaded successfully. Run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
}

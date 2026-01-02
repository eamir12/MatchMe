# Download Noto Serif and Noto Sans CJK (SC/JP/KR) into assets/fonts/
# Usage: powershell -ExecutionPolicy Bypass -File .\tools\download_noto_serif_cjk.ps1

$fonts = @(
  @{name='NotoSerif-Regular.ttf'; urls=@(
      'https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSerif/NotoSerif-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSerif/NotoSerif-Regular.ttf'
    )},
  @{name='NotoSerif-Bold.ttf'; urls=@(
      'https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSerif/NotoSerif-Bold.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSerif/NotoSerif-Bold.ttf'
    )},
  @{name='NotoSansSC-Regular.otf'; urls=@(
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTF/NotoSansSC-Regular.otf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/OTF/NotoSansSC-Regular.otf',
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/TTF/NotoSansSC-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/TTF/NotoSansSC-Regular.ttf'
    )},
  @{name='NotoSansJP-Regular.otf'; urls=@(
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTF/NotoSansJP-Regular.otf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/OTF/NotoSansJP-Regular.otf',
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/TTF/NotoSansJP-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/TTF/NotoSansJP-Regular.ttf'
    )},
  @{name='NotoSansKR-Regular.otf'; urls=@(
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTF/NotoSansKR-Regular.otf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/OTF/NotoSansKR-Regular.otf',
      'https://github.com/googlefonts/noto-cjk/raw/main/Sans/TTF/NotoSansKR-Regular.ttf',
      'https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/TTF/NotoSansKR-Regular.ttf'
    )}
)

$dest = "assets/fonts"
if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

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
      Write-Warning ("Failed: {0}" -f $_.Exception.Message)
    }
  }
  if (-not $downloaded) { $failures += @{name=$f.name; tried=$f.urls} }
}

if ($failures.Count -gt 0) {
  Write-Host "\nSome fonts failed to download. Please fetch them manually from Google Fonts or the Noto repos and place them into assets/fonts/:" -ForegroundColor Yellow
  foreach ($f in $failures) { Write-Host " - $($f.name) (tried: $($f.tried -join ', '))" }
  Write-Host "\nAfter copying, run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
} else {
  Write-Host "\nAll fonts downloaded successfully." -ForegroundColor Green
  Write-Host "Run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
}
# Download Noto fonts used by the app into assets/fonts/
# Usage: Open PowerShell in the repo root and run: .\tools\download_noto_fonts.ps1
# The script will attempt to download a best-effort set of fonts from googlefonts GitHub.

$fonts = @(
  @{name='NotoSans-Regular.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf'},
  @{name='NotoSans-Bold.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf'},
  @{name='NotoSansHebrew-Regular.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansHebrew/NotoSansHebrew-Regular.ttf'},
  @{name='NotoSansHebrew-Bold.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansHebrew/NotoSansHebrew-Bold.ttf'},
  @{name='NotoSansArabic-Regular.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansArabic/NotoSansArabic-Regular.ttf'},
  @{name='NotoSansArabic-Bold.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansArabic/NotoSansArabic-Bold.ttf'},
  @{name='NotoSansTC-Regular.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansTC/NotoSansTC-Regular.ttf'},
  @{name='NotoSansTC-Bold.ttf'; url='https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansTC/NotoSansTC-Bold.ttf'},
  @{name='NotoColorEmoji.ttf'; url='https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf'}
)

$dest = "assets/fonts"
if (!(Test-Path $dest)) {
  New-Item -ItemType Directory -Path $dest | Out-Null
}

$failures = @()
foreach ($f in $fonts) {
  $out = Join-Path $dest $f.name
  try {
    Write-Host "Downloading $($f.name) ..."
    Invoke-WebRequest -Uri $f.url -OutFile $out -UseBasicParsing -ErrorAction Stop
    Write-Host "  -> saved to $out"
  } catch {
    Write-Warning "Failed to download $($f.name) from $($f.url): $_"
    $failures += @{name=$f.name; url=$f.url}
  }
}

if ($failures.Count -gt 0) {
  Write-Host "\nSome fonts failed to download. You can fetch them manually from the links below and place them into assets/fonts/:" -ForegroundColor Yellow
  foreach ($f in $failures) {
    Write-Host " - $($f.name): $($f.url)"
  }
  Write-Host "\nAfter downloading, run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
} else {
  Write-Host "\nAll fonts downloaded successfully." -ForegroundColor Green
  Write-Host "Run: flutter pub get && flutter clean && flutter run -d chrome" -ForegroundColor Green
}

# downloads a curated set of Twemoji PNGs into web/twemoji/
# Usage: powershell -ExecutionPolicy Bypass -File .\tools\download_twemoji_pngs.ps1

$targetDir = Join-Path $PSScriptRoot "..\web\twemoji"
if (-not (Test-Path $targetDir)) {
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}
Write-Host "Target directory: $targetDir"

# Curated list of emoji hex sequences to include (add more as needed)
$codes = @(
  '2764-fe0f','2764', # heart
  '1f622', # 😢
  '1f525', # 🔥
  '1f602', # 😂
  '1f44d', # 👍
  '1f60d', # 😍
  '1f389', # 🎉
  '1f62e', # 😮
  '1f605', # 😅
  '1f604', # 😄
  '1f606', # 😆
  '1f62d', # 😭
  '1f64c', # 🙌
  '1f4af', # 💯
  '1f914', # 🤔
  '1f60e', # 😎
  '1f601', # 😁
  '1f44f', # 👏
  '1f64f', # 🙏
  '1f970', # 🥰
  '1f60b', # 😋
  '1f624'  # 😤
)

$baseUrl = 'https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72'

Write-Host "Downloading Twemoji PNGs to: $targetDir"
foreach ($code in $codes) {
  $url = "$baseUrl/$code.png"
  $out = Join-Path $targetDir "$code.png"
  try {
    Write-Host "Fetching $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop
    Write-Host "Saved $out"
  } catch {
    $msg = $_.Exception.Message
    Write-Warning "Failed to download ${url} - $msg"
  }
}

Write-Host "Done. Remember to commit the files in web/twemoji/ if you want them in the repo."
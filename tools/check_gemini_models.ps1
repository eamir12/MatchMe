<#
.SYNOPSIS
  Checks configured Gemini models against the live Google ListModels API.
.DESCRIPTION
  Reads defaults from supabase/functions/_shared/gemini_config.ts, then (if an
  API key is available) queries
    https://generativelanguage.googleapis.com/v1beta/models?key=KEY
  and reports:
    - configured models that no longer exist / don't support generateContent
    - newer stable gemini-*-flash models not yet in the config
  Exit code 1 = config needs attention, 0 = OK.
.EXAMPLE
  $env:GOOGLE_GEMINI_API_KEY = "AIza..."  # or GOOGLE_AI_API_KEY
  .\tools\check_gemini_models.ps1
  # Override without code change:
  supabase secrets set GEMINI_PRIMARY_MODEL=gemini-3.8-flash
#>

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot "supabase\functions\_shared\gemini_config.ts"

$content = Get-Content -LiteralPath $configPath -Raw
# Only match actual defaults (|| "..."), not models mentioned in comments.
$configured = [regex]::Matches($content, '\|\|\s*"([^"]+)"') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Write-Host "Configured models (from _shared/gemini_config.ts):"
$configured | ForEach-Object { Write-Host "  - $_" }

# Static retirement guard — update when Google announces new dates.
$retired = @("gemini-2.5-flash", "gemini-2.5-flash-lite")  # retire 2026-10-20
$hitRetired = @($configured | Where-Object { $retired -contains $_ })
if ($hitRetired.Count -gt 0) {
  Write-Host "`nERROR: config still references retired/retiring models (retire 2026-10-20):" -ForegroundColor Red
  $hitRetired | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

$apiKey = $env:GOOGLE_GEMINI_API_KEY
if (-not $apiKey) { $apiKey = $env:GOOGLE_AI_API_KEY }
if (-not $apiKey) {
  Write-Host "`nNo GOOGLE_GEMINI_API_KEY set — skipping live ListModels check." -ForegroundColor Yellow
  Write-Host "Docs: https://ai.google.dev/gemini-api/docs/models and https://cloud.google.com/.../model-versions"
  if ($hitRetired.Count -gt 0) { exit 1 } else { exit 0 }
}

$uri = 'https://generativelanguage.googleapis.com/v1beta/models?key=' + $apiKey + '&pageSize=100'
$resp = Invoke-RestMethod -Uri $uri -Method Get
$live = @($resp.models | Where-Object {
  $_.name -match "models/gemini-.*flash" -and $_.supportedGenerationMethods -contains "generateContent"
} | ForEach-Object { ($_.name -replace "^models/", "") } | Sort-Object -Unique)

Write-Host "`nLive Gemini Flash models supporting generateContent:"
$live | ForEach-Object { Write-Host "  - $_" }

$missing = @($configured | Where-Object { $live -notcontains $_ })
if ($missing.Count -gt 0) {
  Write-Host "`nWARNING: configured models NOT returned by ListModels (renamed/retired?):" -ForegroundColor Yellow
  $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

$newer = @($live | Where-Object { $configured -notcontains $_ -and $_ -notmatch "preview|experimental|image|tts|live|audio|cyber" })
if ($newer.Count -gt 0) {
  Write-Host "`nNewer stable models available — consider promoting via Supabase secrets:" -ForegroundColor Cyan
  $newer | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
  Write-Host "`nExample: supabase secrets set GEMINI_PRIMARY_MODEL=<newest>"
}

if ($hitRetired.Count -gt 0 -or $missing.Count -gt 0) { exit 1 } else { exit 0 }

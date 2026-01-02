param(
    [string]$SupabaseUrl = 'https://vazkmvrbshxwyodentng.supabase.co'
)

if (-not $env:SUPABASE_SERVICE_ROLE_KEY) {
    Write-Error "Missing SUPABASE_SERVICE_ROLE_KEY environment variable"
    exit 2
}

$env:SUPABASE_URL = $SupabaseUrl
python .\supabase\scripts\run_fix_interests.py

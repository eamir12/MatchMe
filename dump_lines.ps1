param(
    [string]$FilePath,
    [int]$StartLine,
    [int]$EndLine
)
$lines = Get-Content $FilePath
for ($i = $StartLine - 1; $i -le $EndLine - 1; $i++) {
    Write-Host ("{0:0000}" -f ($i + 1)) + "  " + $lines[$i]
}
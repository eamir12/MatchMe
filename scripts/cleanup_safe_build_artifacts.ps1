param(
    [switch]$Execute,
    [switch]$IncludeLogs = $true,
    [switch]$Aggressive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ItemBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [int64]0
    }

    $item = Get-Item -LiteralPath $LiteralPath -Force

    if (-not $item.PSIsContainer) {
        return [int64]$item.Length
    }

    $files = Get-ChildItem -LiteralPath $LiteralPath -Force -Recurse -File -ErrorAction SilentlyContinue
    if (-not $files) {
        return [int64]0
    }
    $measure = $files | Measure-Object -Property Length -Sum

    if (-not $measure -or $null -eq $measure.Sum) {
        return [int64]0
    }

    return [int64]$measure.Sum
}

function Format-Size {
    param(
        [Parameter(Mandatory = $true)]
        [Int64]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N2} KB' -f ($Bytes / 1KB))
    }

    return "$Bytes B"
}

function Test-IsWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Test-IsLinux {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Linux)
}

function Test-IsMacOS {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX)
}

function Find-JunkFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $results = @()
    foreach ($pattern in $Patterns) {
        $files = Get-ChildItem -LiteralPath $BasePath -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern -or $_.Name -eq $pattern }
        foreach ($f in $files) {
            $results += [PSCustomObject]@{
                Path = $f.FullName
                Type = if ($f.PSIsContainer) { 'Directory' } else { 'File' }
            }
        }
    }
    return $results
}

function New-CleanupTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Directory', 'File')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    [PSCustomObject]@{
        Path   = $Path
        Type   = $Type
        Reason = $Reason
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $normalizedBase = $BasePath.TrimEnd('\', '/')
    $prefix = $normalizedBase + [System.IO.Path]::DirectorySeparatorChar

    if ($TargetPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $TargetPath.Substring($prefix.Length)
    }

    return $TargetPath
}

function Convert-ToLongPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    if ($LiteralPath.StartsWith('\\?\')) {
        return $LiteralPath
    }

    if ($LiteralPath.StartsWith('\\')) {
        return '\\?\UNC\' + $LiteralPath.TrimStart('\')
    }

    return '\\?\' + $LiteralPath
}

function Get-FileLockingProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $lockingProcesses = @()

    try {
        $handleExe = Get-Command handle.exe -ErrorAction SilentlyContinue
        if ($handleExe) {
            $output = & handle.exe $LiteralPath 2>&1
            $pattern = '^(?<pid>\d+)\s+(?<name>\w+).*?\s+(?<path>.+)$'
            foreach ($line in $output) {
                if ($line -match $pattern) {
                    $pid = [int]$matches['pid']
                    $name = $matches['name']
                    $path = $matches['path']
                    if ($path -eq $LiteralPath -or $LiteralPath.StartsWith($path)) {
                        $process = Get-Process -Id $pid -ErrorAction SilentlyContinue
                        if ($process) {
                            $lockingProcesses += [PSCustomObject]@{
                                ProcessId = $pid
                                ProcessName = $name
                                Path = $path
                            }
                        }
                    }
                }
            }
        } elseif (Test-IsWindows) {
            $sessionProcesses = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath }
            foreach ($proc in $sessionProcesses) {
                try {
                    $process = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
                    if ($process) {
                        foreach ($module in $process.Modules) {
                            try {
                                if ($module.FileName -and ($module.FileName -eq $LiteralPath -or $LiteralPath.StartsWith($module.FileName))) {
                                    $lockingProcesses += [PSCustomObject]@{
                                        ProcessId = $process.Id
                                        ProcessName = $process.ProcessName
                                        Path = $module.FileName
                                    }
                                }
                            } catch {
                            }
                        }
                    }
                } catch {
                }
            }
        }
    } catch {
    }

    return $lockingProcesses
}

function Stop-CommonBuildProcesses {
    param(
        [int]$WaitMilliseconds = 1000
    )

    $processNames = @(
        'java', 'javaw', 'gradle', 'dart', 'flutter',
        'adb', 'emulator', 'qemu-system',
        'powershell', 'cmd'
    )

    $stoppedCount = 0
    foreach ($name in $processNames) {
        $processes = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($proc in $processes) {
            try {
                # Only kill processes that look like they're doing Flutter/Dart/Gradle work
                $mainModule = $proc.MainModule
                if ($mainModule -and ($mainModule.FileName -match 'flutter|dart|gradle|java|android')) {
                    Write-Host "  Stopping build process: $($proc.ProcessName) (PID: $($proc.Id))"
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    $stoppedCount++
                }
            } catch {
                # Ignore errors accessing process info
            }
        }
    }

    if ($stoppedCount -gt 0) {
        Write-Host "  Waiting for processes to release handles..."
        Start-Sleep -Milliseconds $WaitMilliseconds
    }

    return $stoppedCount
}

function Stop-FileLockingProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [switch]$Verbose
    )

    # First try to stop common build processes
    Stop-CommonBuildProcesses -WaitMilliseconds 500 | Out-Null

    $lockingProcesses = Get-FileLockingProcesses -LiteralPath $LiteralPath

    if ($lockingProcesses.Count -eq 0) {
        return $false
    }

    if ($Verbose) {
        Write-Host "  Found $($lockingProcesses.Count) process(es) locking the file:"
        foreach ($proc in $lockingProcesses) {
            Write-Host "    - $($proc.ProcessName) (PID: $($proc.ProcessId))"
        }
    }

    foreach ($proc in $lockingProcesses) {
        try {
            if ($Verbose) {
                Write-Host "  Stopping process $($proc.ProcessName) (PID: $($proc.ProcessId))..."
            }
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 300
        } catch {
            if ($Verbose) {
                Write-Warning "  Failed to stop process $($proc.ProcessName): $($_.Exception.Message)"
            }
        }
    }

    # Wait a bit more for handles to be released
    Start-Sleep -Milliseconds 500

    return $true
}

function Remove-DirectoryRobust {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$LongPath
    )

    try {
        [System.IO.Directory]::Delete($LongPath, $true)
        return $true
    } catch {
    }

    $stopped = Stop-FileLockingProcesses -LiteralPath $LiteralPath -Verbose
    if ($stopped) {
        try {
            [System.IO.Directory]::Delete($LongPath, $true)
            return $true
        } catch {
        }
    }

    # Windows-only: robocopy /MIR to empty the directory
    if (Test-IsWindows) {
        $emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cleanup-empty-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            $null = & robocopy $emptyDir $LiteralPath /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1
        } finally {
            Remove-Item -LiteralPath $emptyDir -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    try {
        [System.IO.Directory]::Delete($LongPath, $true)
        return $true
    } catch {
        Remove-Item -LiteralPath $LiteralPath -Force -Recurse -ErrorAction Stop
        return (Test-Path -LiteralPath $LiteralPath) -eq $false
    }
}

function Remove-PathRobust {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Directory', 'File')]
        [string]$Type
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }

    $longPath = Convert-ToLongPath -LiteralPath $LiteralPath

    # Pre-emptively stop common build processes for directories
    if ($Type -eq 'Directory') {
        Stop-CommonBuildProcesses -WaitMilliseconds 1000 | Out-Null
    }

    if ($Type -eq 'File') {
        try {
            [System.IO.File]::SetAttributes($longPath, [System.IO.FileAttributes]::Normal)
        } catch {
        }

        $maxRetries = 3
        for ($i = 0; $i -lt $maxRetries; $i++) {
            try {
                [System.IO.File]::Delete($longPath)
                return
            } catch {
                if ($i -lt $maxRetries - 1) {
                    $stopped = Stop-FileLockingProcesses -LiteralPath $LiteralPath
                    if (-not $stopped) {
                        Start-Sleep -Milliseconds 500
                    }
                }
            }
        }

        Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        return
    }

    $null = Remove-DirectoryRobust -LiteralPath $LiteralPath -LongPath $longPath
    return
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$isWindows = Test-IsWindows
$isLinux   = Test-IsLinux
$isMacOS   = Test-IsMacOS

# -------------------------------------------------------------------
# TARGETS — organised by category
# -------------------------------------------------------------------
$targets = @()

# --- 1.  Flutter / Dart build artifacts (main app) ------------------
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'build')                               -Type 'Directory' -Reason 'Main app Flutter build output'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot '.dart_tool')                          -Type 'Directory' -Reason 'Main app Dart tool local cache'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'coverage')                            -Type 'Directory' -Reason 'Test coverage output'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot '.flutter-plugins')                    -Type 'File'      -Reason 'Generated Flutter plugins list'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot '.flutter-plugins-dependencies')       -Type 'File'      -Reason 'Generated Flutter dependency metadata'

# --- 2.  Flutter / Dart build artifacts (admin app) -----------------
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'matchme_admin\build')                 -Type 'Directory' -Reason 'Admin app Flutter build output'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'matchme_admin\.dart_tool')            -Type 'Directory' -Reason 'Admin app Dart tool local cache'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'matchme_admin\.flutter-plugins')      -Type 'File'      -Reason 'Admin app generated Flutter plugins list'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'matchme_admin\.flutter-plugins-dependencies') -Type 'File' -Reason 'Admin app generated Flutter dependency metadata'

# --- 3.  Android / Gradle build cache (main + admin) ----------------
$androidTargets = @(
    @{Rel = 'android\.gradle';              Type = 'Directory'},
    @{Rel = 'android\.kotlin';              Type = 'Directory'},
    @{Rel = 'android\build';                Type = 'Directory'},
    @{Rel = 'android\local.properties';     Type = 'File'},
    @{Rel = 'matchme_admin\android\.gradle';          Type = 'Directory'},
    @{Rel = 'matchme_admin\android\.kotlin';          Type = 'Directory'},
    @{Rel = 'matchme_admin\android\build';            Type = 'Directory'},
    @{Rel = 'matchme_admin\android\local.properties'; Type = 'File'}
)
foreach ($t in $androidTargets) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $t.Rel) -Type $t.Type -Reason 'Android / Gradle build cache'
}

# --- 4.  iOS ephemeral + CocoaPods (main + admin) ------------------
$iosDirs = @(
    'ios\.symlinks', 'ios\Pods', 'ios\Flutter\ephemeral',
    'matchme_admin\ios\.symlinks', 'matchme_admin\ios\Pods',
    'matchme_admin\ios\Flutter\ephemeral'
)
foreach ($rel in $iosDirs) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'Directory' -Reason 'iOS CocoaPods / Flutter ephemeral'
}

# --- 5.  macOS ephemeral (main + admin) ----------------------------
$macosDirs = @(
    'macos\Flutter\ephemeral',
    'matchme_admin\macos\Flutter\ephemeral'
)
foreach ($rel in $macosDirs) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'Directory' -Reason 'macOS Flutter ephemeral'
}

# --- 6.  Windows ephemeral (main + admin) --------------------------
$windowsDirs = @(
    'windows\flutter\ephemeral',
    'matchme_admin\windows\flutter\ephemeral'
)
foreach ($rel in $windowsDirs) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'Directory' -Reason 'Windows Flutter ephemeral'
}

# --- 7.  Linux ephemeral (main + admin) ----------------------------
$linuxDirs = @(
    'linux\flutter\ephemeral',
    'matchme_admin\linux\flutter\ephemeral'
)
foreach ($rel in $linuxDirs) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'Directory' -Reason 'Linux Flutter ephemeral'
}

# (web/bundle.js is the third-party Passkeys Web SDK — keep it)

# --- 9.  Supabase CLI temp cache -----------------------------------
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'supabase\.temp') -Type 'Directory' -Reason 'Supabase CLI temp / cache'

# --- 10.  IntelliJ IDEA module files (scattered) --------------------
$imlFiles = @(
    'matchme.iml', 'android\matchme_android.iml',
    'matchme_admin\matchme_admin.iml', 'matchme_admin\android\matchme_admin_android.iml'
)
foreach ($rel in $imlFiles) {
    $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'File' -Reason 'IntelliJ module file (auto-generated)'
}

# --- 11.  Orphan Node / package artifacts --------------------------
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'package-lock.json') -Type 'File' -Reason 'Orphan Node.js lock file (not used by Flutter)'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'dependency_outdated.json') -Type 'File' -Reason 'Dependency outdated report'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'dependency_outdated_post.json') -Type 'File' -Reason 'Dependency outdated report'
$targets += New-CleanupTarget -Path (Join-Path $projectRoot 'pub_outdated.json') -Type 'File' -Reason 'Pub outdated report'

# --- 12.  Log / analysis / temp files at project root ---------------
if ($IncludeLogs) {
    $logFileNames = @(
        'AdminLog.txt', 'AndroidLogPhoto.txt', 'Androidlog.txt',
        'Log3.txt', 'log2.txt',
        'analyze_check.txt', 'analyze_final.txt', 'analyze_output.txt',
        'localhost-1770267805124.log'
    )

    foreach ($name in $logFileNames) {
        $targets += New-CleanupTarget -Path (Join-Path $projectRoot $name) -Type 'File' -Reason 'Disposable local log / analysis output'
    }

    $targets += New-CleanupTarget -Path (Join-Path $projectRoot 'tmp_brace_check.py') -Type 'File' -Reason 'Temporary Python script'
}

# -------------------------------------------------------------------
# JUNK FILES — OS / editor artefacts scattered anywhere in the tree
# -------------------------------------------------------------------
$junkPatterns = @(
    '.DS_Store',        # macOS folder metadata
    'Thumbs.db',        # Windows thumbnail cache
    'desktop.ini',      # Windows folder customisation
    '*~',               # Unix / Vim backup files
    '*.swp', '*.swo',   # Vim swap files
    '.directory'        # Linux folder metadata (KDE)
)
$junkFiles = Find-JunkFiles -BasePath $projectRoot -Patterns $junkPatterns
foreach ($j in $junkFiles) {
    $targets += New-CleanupTarget -Path $j.Path -Type $j.Type -Reason 'Cross-platform OS / editor junk file'
}

# -------------------------------------------------------------------
# AGGRESSIVE — opt-in with -Aggressive
# -------------------------------------------------------------------
if ($Aggressive) {
    $aggressiveDirs = @(
        '.devin', '.junie', '.kiro', '.qodo'   # AI agent working directories
    )
    foreach ($rel in $aggressiveDirs) {
        $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'Directory' -Reason 'AI agent working directory (-Aggressive)'
    }

    $aggressiveFiles = @(
        'databasebackup.zip', 'supabase_backup_2025-12-25.zip', 'lib.zip'   # Backup archives
    )
    foreach ($rel in $aggressiveFiles) {
        $targets += New-CleanupTarget -Path (Join-Path $projectRoot $rel) -Type 'File' -Reason 'Backup archive (-Aggressive)'
    }
}

$existingTargets = foreach ($target in $targets) {
    if (Test-Path -LiteralPath $target.Path) {
        $bytes = Get-ItemBytes -LiteralPath $target.Path
        [PSCustomObject]@{
            Path         = $target.Path
            Type         = $target.Type
            Reason       = $target.Reason
            Bytes        = $bytes
            HumanSize    = Format-Size -Bytes $bytes
            RelativePath = Get-RelativePath -BasePath $projectRoot -TargetPath $target.Path
        }
    }
}

if (-not $existingTargets) {
    Write-Host 'No matching cleanup targets were found.'
    exit 0
}

$existingTargets = $existingTargets | Sort-Object Bytes -Descending
$totalBytes = ($existingTargets | Measure-Object -Property Bytes -Sum).Sum

Write-Host ''
Write-Host "Project root: $projectRoot"
Write-Host 'Cleanup targets:'
$existingTargets | Select-Object RelativePath, Type, HumanSize, Reason | Format-Table -AutoSize

Write-Host ''
Write-Host ("Potential space to recover: {0}" -f (Format-Size -Bytes ([int64]$totalBytes)))

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. No files were deleted.'
    Write-Host "Run again with -Execute to remove these targets."
    exit 0
}

Write-Host ''
Write-Host 'Deleting selected targets...'

$failedTargets = @()
$actualRecoveredBytes = [int64]0

foreach ($target in $existingTargets) {
    Write-Host ("Removing {0} ({1})" -f $target.RelativePath, $target.HumanSize)
    try {
        Remove-PathRobust -LiteralPath $target.Path -Type $target.Type
    } catch {
        $failedTargets += [PSCustomObject]@{
            RelativePath = $target.RelativePath
            Message      = $_.Exception.Message
        }
        Write-Warning ("Failed to remove {0}: {1}" -f $target.RelativePath, $_.Exception.Message)
    } finally {
        $remainingBytes = Get-ItemBytes -LiteralPath $target.Path
        $recoveredBytes = [Math]::Max([int64]0, [int64]$target.Bytes - [int64]$remainingBytes)
        $actualRecoveredBytes += $recoveredBytes
    }
}

if ($failedTargets.Count -gt 0) {
    Write-Host ''
    Write-Host ("Recovered so far: {0}" -f (Format-Size -Bytes $actualRecoveredBytes))
    Write-Host 'Cleanup finished with some failures:'
    $failedTargets | Format-Table -AutoSize
    exit 1
}

Write-Host ''
Write-Host ("Cleanup complete. Estimated recovery was {0}; actual recovered space is {1}." -f (Format-Size -Bytes ([int64]$totalBytes)), (Format-Size -Bytes $actualRecoveredBytes))

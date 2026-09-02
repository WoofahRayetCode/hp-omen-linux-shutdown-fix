# OMEN Clean Shutdown — Windows startup handler
# Installed to C:\omen-clean-shutdown.ps1 and run as SYSTEM at boot.

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $env:ProgramData 'omen-clean-shutdown'
$LogFile = Join-Path $LogDir 'omen-clean-shutdown.log'

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Logging must never block shutdown.
    }
}

function Restore-RefindConf {
    param(
        [string]$ConfPath,
        [string]$Restore,
        [string]$RestoreTimeout
    )
    if (-not (Test-Path $ConfPath)) { return }
    $c = Get-Content $ConfPath -Raw

    if (Test-Path $Restore) {
        $s = (Get-Content $Restore -Raw).Trim()
        Remove-Item -Force $Restore -ErrorAction SilentlyContinue
        if ($s -notmatch '^default_selection') { $s = "default_selection $s" }
        $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', $s
    } else {
        $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', 'default_selection "Linux,vmlinuz"'
    }

    $timeoutVal = 'timeout 0'
    if (Test-Path $RestoreTimeout) {
        $t = (Get-Content $RestoreTimeout -Raw).Trim()
        Remove-Item -Force $RestoreTimeout -ErrorAction SilentlyContinue
        if ($t -match '^timeout[ \t]+') {
            $timeoutVal = $t
        } else {
            $timeoutVal = "timeout $t"
        }
    }
    if ($timeoutVal -match '-1') {
        $timeoutVal = 'timeout 0'
    }

    if ($c -match '(?m)^[ \t]*timeout[ \t]+') {
        $c = $c -replace '(?m)^[ \t]*timeout[ \t]+.*$', $timeoutVal
    } else {
        $c = $c + "`n$timeoutVal`n"
    }
    [System.IO.File]::WriteAllText($ConfPath, $c)
}

function Find-EfiRoot {
    if (Test-Path 'S:\EFI') { return 'S:' }

    foreach ($letter in @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','T','U','V','W','X','Y','Z')) {
        if (Test-Path "${letter}:\EFI") {
            return "${letter}:"
        }
    }

    $mountedTemp = $false
    for ($i = 0; $i -lt 5; $i++) {
        cmd /c "mountvol B: /S" | Out-Null
        if (Test-Path 'B:\EFI') {
            return 'B:'
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Find-FlagPath {
    param([string]$EfiRoot)
    $candidates = @(
        "$EfiRoot\EFI\omen\shutdown_flag",
        "$EfiRoot\EFI\refind\shutdown_flag",
        "$EfiRoot\EFI\Microsoft\Boot\shutdown_flag"
    )
    foreach ($letter in @('S','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','T','U','V','W','X','Y','Z','B')) {
        $candidates += @(
            "${letter}:\EFI\omen\shutdown_flag",
            "${letter}:\EFI\refind\shutdown_flag"
        )
    }
    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand)) {
            return $cand
        }
    }
    return $null
}

Write-Log 'Startup handler began.'

$efiDrive = Find-EfiRoot
$mountedTemp = $false
if ($efiDrive -eq 'B:') {
    $mountedTemp = $true
}

if (-not $efiDrive) {
    Write-Log 'Could not mount EFI System Partition.'
    exit 1
}

Write-Log "Using EFI drive $efiDrive"

$flag = Find-FlagPath -EfiRoot $efiDrive
$confCandidates = @(
    "$efiDrive\EFI\refind\refind.conf",
    "$efiDrive\EFI\Microsoft\Boot\refind.conf",
    "S:\EFI\refind\refind.conf"
)
$conf = $null
foreach ($cand in $confCandidates) {
    if (Test-Path $cand) {
        $conf = $cand
        break
    }
}

if ($conf) {
    $efiDir = Split-Path -Parent $conf
    $restore = Join-Path $efiDir 'default_selection_restore'
    $restoreTimeout = Join-Path $efiDir 'default_selection_restore_timeout'
    $refindSrc = Join-Path $efiDir 'refind_x64.efi'
    $bootmgfw = Join-Path $efiDrive 'EFI\Microsoft\Boot\bootmgfw.efi'
    if ((Test-Path $refindSrc) -and (Test-Path $bootmgfw)) {
        $size = (Get-Item $bootmgfw).Length
        if ($size -gt 1048576) {
            Write-Log "bootmgfw.efi is $size bytes; restoring rEFInd over it."
            Copy-Item -Force $bootmgfw (Join-Path (Split-Path -Parent $bootmgfw) 'bootmgfw.efi.bak')
            Copy-Item -Force $refindSrc $bootmgfw
        }
    }
}

if ($flag) {
    Write-Log "shutdown_flag present at $flag; powering off."
    Remove-Item -Force $flag -ErrorAction SilentlyContinue
    if ($conf) {
        $efiDir = Split-Path -Parent $conf
        Restore-RefindConf -ConfPath $conf `
            -Restore (Join-Path $efiDir 'default_selection_restore') `
            -RestoreTimeout (Join-Path $efiDir 'default_selection_restore_timeout')
    }
    if ($mountedTemp) { cmd /c "mountvol B: /D" | Out-Null }
    shutdown /s /f /t 0
    exit 0
}

if ($conf) {
    $c = Get-Content $conf -Raw
    if ($c -match '(?m)^[ \t]*timeout[ \t]+-1') {
        Write-Log 'Orphaned timeout -1; restoring rEFInd defaults.'
        $efiDir = Split-Path -Parent $conf
        Restore-RefindConf -ConfPath $conf `
            -Restore (Join-Path $efiDir 'default_selection_restore') `
            -RestoreTimeout (Join-Path $efiDir 'default_selection_restore_timeout')
    }
}

if ($mountedTemp) { cmd /c "mountvol B: /D" | Out-Null }
Write-Log 'Normal startup; no shutdown flag.'

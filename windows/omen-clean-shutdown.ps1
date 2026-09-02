# OMEN Clean Shutdown — Windows startup handler
# Installed to C:\omen-clean-shutdown.ps1 and run as SYSTEM at boot.

# Empty optical/card-reader letters throw if Stop is in effect and abort
# before the shutdown flag is found. Probe with SilentlyContinue instead.
$ErrorActionPreference = 'Continue'
$LogDir = Join-Path $env:ProgramData 'omen-clean-shutdown'
$LogFile = Join-Path $LogDir 'omen-clean-shutdown.log'
$script:TempMounts = @()

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
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
    if (-not (Test-Path -LiteralPath $ConfPath -ErrorAction SilentlyContinue)) { return }
    $c = Get-Content -LiteralPath $ConfPath -Raw -ErrorAction SilentlyContinue
    if (-not $c) { return }

    if (Test-Path -LiteralPath $Restore -ErrorAction SilentlyContinue) {
        $s = (Get-Content -LiteralPath $Restore -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item -LiteralPath $Restore -Force -ErrorAction SilentlyContinue
        if ($s -notmatch '^default_selection') { $s = "default_selection $s" }
        $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', $s
    } else {
        $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', 'default_selection "Linux,vmlinuz"'
    }

    $timeoutVal = 'timeout 0'
    if (Test-Path -LiteralPath $RestoreTimeout -ErrorAction SilentlyContinue) {
        $t = (Get-Content -LiteralPath $RestoreTimeout -Raw -ErrorAction SilentlyContinue).Trim()
        Remove-Item -LiteralPath $RestoreTimeout -Force -ErrorAction SilentlyContinue
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

function Get-FreeDriveLetter {
    $used = @{}
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.Name) {
                $used[$d.Name.Substring(0, 1).ToUpperInvariant()] = $true
            }
        }
    } catch {}
    foreach ($m in $script:TempMounts) {
        if ($m.Letter) { $used[$m.Letter.ToUpperInvariant()] = $true }
    }
    foreach ($letter in @('B', 'S', 'Y', 'Z', 'Q', 'P', 'O', 'N')) {
        if (-not $used.ContainsKey($letter)) { return $letter }
    }
    return $null
}

function Register-TempMount {
    param(
        [string]$Letter,
        [ValidateSet('mountvol', 'accesspath')]
        [string]$How,
        [string]$AccessPath = ''
    )
    $script:TempMounts += [pscustomobject]@{
        Letter     = $Letter
        How        = $How
        AccessPath = $AccessPath
    }
}

function Dismount-TempEsps {
    foreach ($m in $script:TempMounts) {
        try {
            if ($m.How -eq 'mountvol') {
                cmd /c "mountvol $($m.Letter): /D" | Out-Null
            } elseif ($m.AccessPath) {
                Remove-PartitionAccessPath -AccessPath $m.AccessPath -ErrorAction SilentlyContinue
            } else {
                cmd /c "mountvol $($m.Letter): /D" | Out-Null
            }
        } catch {}
    }
    $script:TempMounts = @()
}

function Test-FlagAtRoot {
    param([string]$Root)
    if (-not $Root) { return $null }
    $root = $Root.TrimEnd('\')
    foreach ($rel in @(
            'EFI\omen\shutdown_flag',
            'EFI\refind\shutdown_flag',
            'EFI\Microsoft\Boot\shutdown_flag',
            'efi\omen\shutdown_flag',
            'efi\refind\shutdown_flag'
        )) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
            return $p
        }
    }
    return $null
}

function Find-RefindConfAtRoot {
    param([string]$Root)
    if (-not $Root) { return $null }
    $root = $Root.TrimEnd('\')
    foreach ($rel in @(
            'EFI\refind\refind.conf',
            'EFI\Microsoft\Boot\refind.conf',
            'efi\refind\refind.conf'
        )) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
            return $p
        }
    }
    return $null
}

function Mount-FirmwareEsp {
    $letter = Get-FreeDriveLetter
    if (-not $letter) { return $null }
    for ($i = 0; $i -lt 5; $i++) {
        cmd /c "mountvol ${letter}: /S" | Out-Null
        if (Test-Path -LiteralPath "${letter}:\EFI" -ErrorAction SilentlyContinue) {
            Register-TempMount -Letter $letter -How 'mountvol'
            return "${letter}:"
        }
        Start-Sleep -Seconds 1
    }
    cmd /c "mountvol ${letter}: /D" 2>$null | Out-Null
    return $null
}

function Mount-AllGptEsps {
    $mounted = @()
    $espGuid = [guid]'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
    try {
        $parts = @(Get-Partition -ErrorAction Stop | Where-Object { $_.GptType -eq $espGuid })
    } catch {
        return $mounted
    }
    foreach ($part in $parts) {
        if ($part.DriveLetter) {
            $mounted += "$($part.DriveLetter):"
            continue
        }
        $letter = Get-FreeDriveLetter
        if (-not $letter) { continue }
        $access = "${letter}:\"
        try {
            Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath $access -ErrorAction Stop
            Register-TempMount -Letter $letter -How 'accesspath' -AccessPath $access
            $mounted += "${letter}:"
        } catch {
            try {
                cmd /c "mountvol ${letter}: /S" | Out-Null
            } catch {}
        }
    }
    return $mounted
}

function Get-CandidateEfiRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Root([string]$r) {
        if (-not $r) { return }
        $key = $r.TrimEnd('\').ToUpperInvariant()
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-Path -LiteralPath (Join-Path $r 'EFI') -ErrorAction SilentlyContinue) -and
            -not (Test-Path -LiteralPath (Join-Path $r 'efi') -ErrorAction SilentlyContinue)) {
            return
        }
        $seen[$key] = $true
        $roots.Add($r.TrimEnd('\'))
    }

    $fw = Mount-FirmwareEsp
    if ($fw) { Add-Root $fw }

    foreach ($letter in @('S', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'B')) {
        Add-Root "${letter}:"
    }

    foreach ($r in (Mount-AllGptEsps)) {
        Add-Root $r
    }

    return @($roots)
}

function Request-PowerOff {
    Write-Log 'Issuing shutdown /s /f /t 0'
    & shutdown.exe /s /f /t 0
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Log "shutdown.exe exited $LASTEXITCODE; trying Stop-Computer"
        try { Stop-Computer -Force -ErrorAction Stop } catch {
            Write-Log "Stop-Computer failed: $($_.Exception.Message)"
        }
    }
}

Write-Log 'Startup handler began.'

try {
    $efiRoots = @(Get-CandidateEfiRoots)
    Write-Log ("EFI roots: " + ($(if ($efiRoots) { $efiRoots -join ', ' } else { 'none' })))

    $flag = $null
    $flagRoot = $null
    foreach ($root in $efiRoots) {
        $hit = Test-FlagAtRoot $root
        if ($hit) {
            $flag = $hit
            $flagRoot = $root
            break
        }
    }

    $conf = $null
    $confSearch = @($efiRoots)
    if ($flagRoot) { $confSearch = @($flagRoot) + $efiRoots }
    foreach ($root in $confSearch) {
        $hit = Find-RefindConfAtRoot $root
        if ($hit) {
            $conf = $hit
            break
        }
    }

    if ($conf) {
        $efiDir = Split-Path -Parent $conf
        $confRoot = Split-Path -Parent (Split-Path -Parent $efiDir)
        if (-not $confRoot) { $confRoot = $flagRoot }
        $bootmgfw = $null
        foreach ($root in @($confRoot, $flagRoot) + $efiRoots) {
            if (-not $root) { continue }
            $candidate = Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi'
            if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
                $bootmgfw = $candidate
                break
            }
        }
        $refindSrc = Join-Path $efiDir 'refind_x64.efi'
        if ((Test-Path -LiteralPath $refindSrc -ErrorAction SilentlyContinue) -and $bootmgfw) {
            $size = (Get-Item -LiteralPath $bootmgfw -ErrorAction SilentlyContinue).Length
            if ($size -gt 1048576) {
                Write-Log "bootmgfw.efi is $size bytes; restoring rEFInd over it."
                Copy-Item -Force $bootmgfw (Join-Path (Split-Path -Parent $bootmgfw) 'bootmgfw.efi.bak') -ErrorAction SilentlyContinue
                Copy-Item -Force $refindSrc $bootmgfw -ErrorAction SilentlyContinue
            }
        }
    }

    if ($flag) {
        Write-Log "shutdown_flag present at $flag; powering off."
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        if ($conf) {
            $efiDir = Split-Path -Parent $conf
            Restore-RefindConf -ConfPath $conf `
                -Restore (Join-Path $efiDir 'default_selection_restore') `
                -RestoreTimeout (Join-Path $efiDir 'default_selection_restore_timeout')
        }
        Dismount-TempEsps
        Request-PowerOff
        exit 0
    }

    if ($conf) {
        $c = Get-Content -LiteralPath $conf -Raw -ErrorAction SilentlyContinue
        if ($c -match '(?m)^[ \t]*timeout[ \t]+-1') {
            Write-Log 'Orphaned timeout -1; restoring rEFInd defaults.'
            $efiDir = Split-Path -Parent $conf
            Restore-RefindConf -ConfPath $conf `
                -Restore (Join-Path $efiDir 'default_selection_restore') `
                -RestoreTimeout (Join-Path $efiDir 'default_selection_restore_timeout')
        }
    }

    Dismount-TempEsps
    Write-Log 'Normal startup; no shutdown flag.'
} catch {
    Write-Log ("Handler error: " + $_.Exception.Message)
    Dismount-TempEsps
    exit 1
}

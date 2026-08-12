param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message"
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$TaskName = 'OMEN Clean Shutdown'
$BatPath = 'C:\omen-clean-shutdown.bat'

if ($Uninstall) {
    Write-Info "Removing scheduled task and batch file..."
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Remove-Item -Force -ErrorAction SilentlyContinue $BatPath
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $desktopPath 'Reboot to rEFInd.lnk')
    Write-Info 'Removed.'
    exit 0
}

Write-Info "Creating batch file..."
$batch = @'
@echo off
set "EFI=B:"

:: Try mounting EFI partition up to 5 times (waiting for storage service at early boot)
set /a count=0
:MOUNT_LOOP
mountvol %EFI% /S >nul 2>&1
if exist %EFI%\EFI (
    goto MOUNT_SUCCESS
)
set /a count+=1
if %count% lss 5 (
    timeout /t 2 /nobreak >nul
    goto MOUNT_LOOP
)
exit /b

:MOUNT_SUCCESS
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& {
    $refindSrc = 'B:\EFI\refind\refind_x64.efi'
    $bootmgfw = 'B:\EFI\Microsoft\Boot\bootmgfw.efi'

    # Sanity Check 1: Protect rEFInd bootloader binary if overwritten by Windows update
    if ((Test-Path $refindSrc) -and (Test-Path $bootmgfw)) {
        $size = (Get-Item $bootmgfw).Length
        if ($size -gt 1048576) {
            Copy-Item -Force $bootmgfw 'B:\EFI\Microsoft\Boot\bootmgfw.efi.bak'
            Copy-Item -Force $refindSrc $bootmgfw
        }
    }

    # Locate refind.conf
    $conf = 'B:\EFI\Microsoft\Boot\refind.conf'
    if (-not (Test-Path $conf)) { $conf = 'B:\EFI\refind\refind.conf' }

    $flag = 'B:\EFI\refind\shutdown_flag'
    $restore = 'B:\EFI\refind\default_selection_restore'
    $restoreTimeout = 'B:\EFI\refind\default_selection_restore_timeout'

    # Helper function to safely restore timeout and default_selection in refind.conf
    function Restore-RefindConf {
        param([string]$confPath)
        if (-not (Test-Path $confPath)) { return }
        $c = Get-Content $confPath -Raw

        # 1. Restore default_selection
        if (Test-Path $restore) {
            $s = (Get-Content $restore -Raw).Trim()
            Remove-Item -Force $restore -ErrorAction SilentlyContinue
            if ($s -notmatch '^default_selection') { $s = "default_selection $s" }
            $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', $s
        } else {
            # Default fallback selection
            $c = $c -replace '(?m)^[ \t]*default_selection[ \t]+.*$', 'default_selection "Linux,vmlinuz"'
        }

        # 2. Restore timeout (rEFInd config: 'timeout 0' or 'timeout 0' means wait indefinitely for user choice)
        # Note: In rEFInd, 'timeout 0' disables auto-boot timeout and keeps menu up until user chooses an OS option.
        $timeoutVal = 'timeout 0'
        if (Test-Path $restoreTimeout) {
            $t = (Get-Content $restoreTimeout -Raw).Trim()
            Remove-Item -Force $restoreTimeout -ErrorAction SilentlyContinue
            if ($t -match '^timeout[ \t]+') { 
                $timeoutVal = $t 
            } else { 
                $timeoutVal = "timeout $t" 
            }
        }
        # If timeout was -1 or invalid, force timeout 0 so menu never autoboots
        if ($timeoutVal -match '-1') {
            $timeoutVal = 'timeout 0'
        }

        if ($c -match '(?m)^[ \t]*timeout[ \t]+') {
            $c = $c -replace '(?m)^[ \t]*timeout[ \t]+.*$', $timeoutVal
        } else {
            $c = $c + "`n$timeoutVal`n"
        }
        [System.IO.File]::WriteAllText($confPath, $c)
    }

    if (Test-Path $flag) {
        # Shutdown workflow triggered from Linux
        Remove-Item -Force $flag -ErrorAction SilentlyContinue
        Restore-RefindConf -confPath $conf
        mountvol B: /D
        shutdown /s /f /t 3
        exit
    } else {
        # Normal Windows startup sanity check: Make sure refind.conf isn't left stuck with timeout -1
        if (Test-Path $conf) {
            $c = Get-Content $conf -Raw
            if ($c -match '(?m)^[ \t]*timeout[ \t]+-1') {
                Restore-RefindConf -confPath $conf
            }
        }
    }
}"

mountvol %EFI% /D
'@


Set-Content -Path $BatPath -Value $batch -Encoding ASCII

Write-Info "Creating startup task..."
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\omen-clean-shutdown.bat"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Info 'Setting Windows to treat hardware clock as UTC (fixes Linux/Windows time mismatch)...'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'RealTimeIsUniversal' -Value 1 -Type DWord -Force

Write-Info 'Disabling Fast Startup and Hibernation to prevent pre-login hangs...'
powercfg /h off | Out-Null
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force

Write-Info 'Preventing pre-login automatic setup and app launching prior to user logon...'
$userDevicePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if (-not (Test-Path $userDevicePath)) { New-Item -Path $userDevicePath -Force | Out-Null }
Set-ItemProperty -Path $userDevicePath -Name 'UserDeviceSignIn' -Value 0 -Type DWord -Force

Write-Info 'Creating "Reboot to rEFInd" Desktop Shortcut...'
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'Reboot to rEFInd.lnk'

# Dynamic search for rEFInd boot entry GUID
$refindGuid = $null
$bcdOutput = bcdedit /enum firmware 2>$null
if ($bcdOutput) {
    $currentGuid = $null
    foreach ($line in $bcdOutput) {
        if ($line -match 'identifier\s+\{([a-f0-9\-]+)\}') {
            $currentGuid = $matches[1]
        }
        if ($currentGuid -and ($line -match 'rEFInd' -or $line -match '\\EFI\\refind\\refind_x64\.efi')) {
            $refindGuid = "{$currentGuid}"
            break
        }
    }
}

if (-not $refindGuid) {
    # Fallback to bootmgr if specific entry not matched
    $refindGuid = '{bootmgr}'
}

$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"bcdedit /set {fwbootmgr} bootsequence $refindGuid; shutdown /r /t 0`""
$shortcut.Description = 'Reboot immediately into the rEFInd Boot Manager'
$shortcut.IconLocation = 'shell32.dll,238'
$shortcut.Save()

# Set shortcut to Run as Administrator (Byte offset 21 bit 5)
$bytes = [System.IO.File]::ReadAllBytes($shortcutPath)
$bytes[21] = $bytes[21] -bor 0x20
[System.IO.File]::WriteAllBytes($shortcutPath, $bytes)

Write-Info 'Installed.'
Write-Host ''
Write-Host 'Task name: OMEN Clean Shutdown'
Write-Host 'Batch file: C:\omen-clean-shutdown.bat'
Write-Host "Desktop shortcut created: $shortcutPath"
Write-Host 'Configured for Windows on primary drive (Disk 0) and Linux on secondary drive (Disk 1).'
Write-Host 'Use the task as part of the Linux shutdown flow described in the README.'

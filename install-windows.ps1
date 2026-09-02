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
$Ps1Path = 'C:\omen-clean-shutdown.ps1'
$BatPath = 'C:\omen-clean-shutdown.bat'
$LogDir = Join-Path $env:ProgramData 'omen-clean-shutdown'
$SourcePs1 = Join-Path $PSScriptRoot 'windows\omen-clean-shutdown.ps1'

if ($Uninstall) {
    Write-Info "Removing scheduled task and handler files..."
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Remove-Item -Force -ErrorAction SilentlyContinue $Ps1Path
    Remove-Item -Force -ErrorAction SilentlyContinue $BatPath
    $desktopPath = [System.Environment]::GetFolderPath('Desktop')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $desktopPath 'Reboot to rEFInd.lnk')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $desktopPath 'Reboot to Linux boot manager.lnk')
    Write-Info 'Removed.'
    exit 0
}

if (-not (Test-Path $SourcePs1)) {
    throw "Missing handler source: $SourcePs1"
}

Write-Info "Installing Windows handler to $Ps1Path..."
Copy-Item -Force $SourcePs1 $Ps1Path

$batch = @"
@echo off
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$Ps1Path"
"@
Set-Content -Path $BatPath -Value $batch -Encoding ASCII

Write-Info "Creating startup task..."
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Ps1Path`""
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
foreach ($t in @($bootTrigger, $logonTrigger)) {
    try { $t.Delay = 'PT0S' } catch { }
}
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew
try { $settings.Priority = 4 } catch { }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($bootTrigger, $logonTrigger) -Principal $principal -Settings $settings -Force | Out-Null

Write-Info 'Setting Windows to treat hardware clock as UTC (fixes Linux/Windows time mismatch)...'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'RealTimeIsUniversal' -Value 1 -Type DWord -Force

Write-Info 'Disabling Fast Startup and Hibernation to prevent pre-login hangs...'
powercfg /h off | Out-Null
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force

Write-Info 'Preventing pre-login automatic setup and app launching prior to user logon...'
$userDevicePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if (-not (Test-Path $userDevicePath)) { New-Item -Path $userDevicePath -Force | Out-Null }
Set-ItemProperty -Path $userDevicePath -Name 'UserDeviceSignIn' -Value 0 -Type DWord -Force

Write-Info 'Creating "Reboot to Linux boot manager" Desktop Shortcut...'
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'Reboot to Linux boot manager.lnk'
$legacyShortcutPath = Join-Path $desktopPath 'Reboot to rEFInd.lnk'

$linuxGuid = $null
$bcdOutput = bcdedit /enum firmware 2>$null
if ($bcdOutput) {
    $currentGuid = $null
    $currentDesc = ''
    $currentPath = ''
    $entries = @()
    foreach ($line in $bcdOutput) {
        if ($line -match 'identifier\s+\{([a-f0-9\-]+)\}') {
            if ($currentGuid) {
                $entries += [pscustomobject]@{ Guid = $currentGuid; Desc = $currentDesc; Path = $currentPath }
            }
            $currentGuid = $matches[1]
            $currentDesc = ''
            $currentPath = ''
        }
        if ($line -match 'description\s+(.+)$') { $currentDesc = $matches[1].Trim() }
        if ($line -match 'path\s+(.+)$') { $currentPath = $matches[1].Trim() }
    }
    if ($currentGuid) {
        $entries += [pscustomobject]@{ Guid = $currentGuid; Desc = $currentDesc; Path = $currentPath }
    }
    foreach ($pattern in @('rEFInd', 'limine', 'GRUB', 'CachyOS', 'Fedora', 'ubuntu', 'systemd-boot', 'Linux')) {
        $hit = $entries | Where-Object { $_.Desc -match $pattern -or $_.Path -match $pattern } | Select-Object -First 1
        if ($hit) {
            $linuxGuid = "{$($hit.Guid)}"
            break
        }
    }
}

if (-not $linuxGuid) {
    $linuxGuid = '{bootmgr}'
}

$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"bcdedit /set {fwbootmgr} bootsequence $linuxGuid; shutdown /r /t 0`""
$shortcut.Description = 'Reboot immediately into the Linux boot manager (Limine, GRUB, or rEFInd)'
$shortcut.IconLocation = 'shell32.dll,238'
$shortcut.Save()
if (Test-Path $legacyShortcutPath) {
    Remove-Item -Force $legacyShortcutPath -ErrorAction SilentlyContinue
}

$bytes = [System.IO.File]::ReadAllBytes($shortcutPath)
$bytes[21] = $bytes[21] -bor 0x20
[System.IO.File]::WriteAllBytes($shortcutPath, $bytes)

Write-Info 'Installed.'
Write-Host ''
Write-Host 'Task name: OMEN Clean Shutdown'
Write-Host "Handler: $Ps1Path"
Write-Host "Legacy wrapper: $BatPath"
Write-Host "Log: $LogDir\omen-clean-shutdown.log"
Write-Host "Desktop shortcut created: $shortcutPath"
Write-Host 'Configured for Windows on primary drive (Disk 0) and Linux on secondary drive (Disk 1).'
Write-Host 'Use the task as part of the Linux shutdown flow described in the README.'

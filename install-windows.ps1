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
    Write-Info 'Removed.'
    exit 0
}

Write-Info "Creating batch file..."
$batch = @'
@echo off
set "EFI=B:"
mountvol %EFI% /S
if exist "%EFI%\EFI\refind\shutdown_flag" (
    del "%EFI%\EFI\refind\shutdown_flag"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='B:\EFI\Microsoft\Boot\refind.conf'; if (-not (Test-Path $p)) { $p='B:\EFI\refind\refind.conf' }; $r='B:\EFI\refind\default_selection_restore'; $c=Get-Content $p -Raw; if (Test-Path $r) { $s=(Get-Content $r -Raw).Trim(); $c=$c -replace '^default_selection .+',$s; Remove-Item $r } else { $c=$c -replace '^default_selection .*','default_selection ""Linux,vmlinuz""' }; $c=$c -replace '^timeout .*','timeout 10'; Set-Content -Encoding ASCII -Path $p -Value $c"
    mountvol %EFI% /D
    shutdown /s /t 5
) else (
    mountvol %EFI% /D
)
'@

Set-Content -Path $BatPath -Value $batch -Encoding ASCII

Write-Info "Creating startup task..."
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "C:\omen-clean-shutdown.bat"'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Info 'Setting Windows to treat hardware clock as UTC (fixes Linux/Windows time mismatch)...'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'RealTimeIsUniversal' -Value 1 -Type DWord -Force

Write-Info 'Installed.'
Write-Host ''
Write-Host 'Task name: OMEN Clean Shutdown'
Write-Host 'Batch file: C:\omen-clean-shutdown.bat'
Write-Host 'Configured for Windows on primary drive (Disk 0) and Linux on secondary drive (Disk 1).'
Write-Host 'Use the task as part of the Linux shutdown flow described in the README.'

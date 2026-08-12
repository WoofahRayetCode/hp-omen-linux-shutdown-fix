# HP OMEN Linux Clean Shutdown Fix (Dual-Drive Setup)

This repo packages the HP OMEN shutdown workaround into two scripts:

- `install-linux.sh` for Nobara/Fedora, CachyOS, Arch, and other systemd-based distros running on the secondary drive
- `install-windows.ps1` for Windows running on the primary drive

The goal is simple: when you shut down from Linux, the laptop reboots into Windows first, Windows finishes the power-off correctly, and the machine ends up fully off.

## Dual-Drive Architecture

This setup is optimized for dual-disk laptop configurations:
- **Primary Drive (Disk 0)**: Windows 11 installation and primary UEFI System Partition (ESP) containing rEFInd / Windows Boot Manager.
- **Secondary Drive (Disk 1)**: Linux installation (Nobara/Fedora, Arch, CachyOS, etc.) with root `/` and swap/data partitions.

Having Linux on a secondary drive with Windows on the primary drive keeps drive management simple and isolates OS updates while sharing the primary EFI partition for rEFInd boot management.

## Why this exists

Some HP OMEN laptops do not fully power off when Linux shuts down. The screen goes dark, but the machine may stay warm or keep draining battery. Windows shuts down normally, so this workaround uses Windows as the final step.

## How it works

1. You trigger the shutdown from Linux (OMEN AI/Copilot key, shortcut, or terminal).
2. The Linux script saves the current rEFInd `default_selection`, sets it to `"Windows"`, and sets `timeout -1` so rEFInd boots Windows immediately.
3. The script creates a flag file on the shared EFI partition and reboots.
4. Windows starts from the primary drive. A scheduled task running as `SYSTEM` sees the flag, restores the saved rEFInd default, deletes the flag, and shuts Windows down.
5. The laptop is now fully off. Next power-on boots back into Linux on the secondary drive normally.

## Requirements

- UEFI firmware with **Secure Boot disabled**
- Dual-drive setup: Windows installed on **Primary Drive (Disk 0)**, Linux on **Secondary Drive (Disk 1)**
- **rEFInd** installed as the boot manager on the primary EFI partition
- Linux using **systemd**

## Supported Linux distros

- Nobara / Fedora
- CachyOS
- Arch Linux
- Other systemd-based distros with rEFInd (may require small tweaks)

The Linux installer auto-detects the rEFInd binary path used by Fedora/Nobara (`/usr/share/rEFInd/refind/refind_x64.efi`) and Arch/CachyOS (`/usr/share/refind/refind_x64.efi`).

## Files

| File | Purpose |
|---|---|
| `install-linux.sh` | Set up the Linux side (secondary drive) |
| `install-windows.ps1` | Set up the Windows side (primary drive) and fix the hardware clock timezone |
| `C:\omen-clean-shutdown.bat` | Windows startup handler |
| `/usr/local/bin/omen-clean-shutdown-launcher` | Linux shortcut target |
| `/usr/local/bin/omen-clean-shutdown.sh` | Linux shutdown logic |
| `/usr/local/bin/refind-protect.sh` | Restores rEFInd if Windows overwrites the boot manager |

## Installation Guide

Do the Windows side first on your primary drive, then the Linux side on your secondary drive.

### 1. On Windows (Primary Drive - Disk 0)

Open PowerShell as Administrator in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

This sets up the `OMEN Clean Shutdown` startup task and configures the `RealTimeIsUniversal` registry key so Windows treats the hardware clock as UTC, preventing time drift when dual-booting between Windows and Linux.

### 2. On Linux (Secondary Drive - Disk 1)

Install rEFInd first if it is not already installed:

```bash
# CachyOS / Arch
sudo pacman -S refind
sudo refind-install

# Nobara / Fedora
sudo dnf install refind
sudo refind-install
```

Then run the Linux installer. The script auto-mounts the EFI partition at `/boot/efi` if needed.

```bash
sudo bash ./install-linux.sh
```

If the script lives on a mounted Windows drive/partition, you can run it directly:

```bash
cd /mnt/windows/Users/ericp/OneDrive/Documents/GitHub/hp-omen-linux-shutdown-fix
sudo bash ./install-linux.sh
```

## Use

Bind your AI key or another shortcut to:

```bash
/usr/local/bin/omen-clean-shutdown-launcher
```

On GNOME, add it in Settings as a custom shortcut. The launcher uses `sudo` and the installer adds the sudo rule for the command it needs.
If you are on GNOME, the Linux installer will ask you to press the button once and will try to bind it automatically. If detection fails, it falls back to `XF86Launch2`.

## Remove

### Linux

```bash
sudo bash ./install-linux.sh remove
```

### Windows

```powershell
.\install-windows.ps1 -Uninstall
```

## Environment variables

You can override paths before running `install-linux.sh`:

| Variable | Default | Description |
|---|---|---|
| `EFI_MOUNT` | `/boot/efi` | Where the EFI partition is mounted |
| `REFIND_CONF` | auto-detected | Path to `refind.conf` |
| `REFIND_SOURCE` | auto-detected | Path to `refind_x64.efi` |
| `REFIND_TARGET` | `$EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi` | Where to restore rEFInd if Windows overwrites it |
| `FLAG_FILE` | `$EFI_MOUNT/EFI/refind/shutdown_flag` | Flag file that tells Windows to finish shutdown |
| `RESTORE_FILE` | `$EFI_MOUNT/EFI/refind/default_selection_restore` | Saved rEFInd default selection |

## Notes

- This is a workaround, not a firmware fix.
- The OMEN AI/Copilot key usually appears as `XF86Launch2` on Linux, but the installer will try to detect `KEY_PROG1` through `KEY_PROG4` first.
- The EFI paths used here match the OMEN layout from the original guide; if your machine uses different paths, adjust the scripts or set the environment variables above.
- This workaround relies on rEFInd. It will not work with Limine, GRUB, or systemd-boot without significant changes.


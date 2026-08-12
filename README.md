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
2. The Linux script saves the current rEFInd `default_selection` and `timeout`, sets `default_selection "Windows"` and `timeout -1` so rEFInd boots Windows immediately during the automated shutdown cycle.
3. The script creates a flag file on the shared EFI partition and reboots.
4. Windows starts from the primary drive. A scheduled task running as `SYSTEM` sees the flag, restores the saved rEFInd default and timeout (`timeout 0` for persistent interactive boot menu), deletes the flag, and shuts Windows down.
5. The laptop is now fully off. Next power-on boots back into the interactive rEFInd boot menu normally.

### Reboot & Boot Menu Behavior

* **rEFInd Menu Persistence (`timeout 0`)**: Restoring `timeout 0` ensures that the rEFInd graphical boot menu displays indefinitely on normal power-on or reboot until an OS option is chosen.
* **Standard Restarts**: Performing a standard **Restart** (from either Windows or Linux) will bring up the **rEFInd boot menu** normally. You do not need to do a full shutdown and manual power-on to switch operating systems when restarting. The automated Windows shutdown sequence is only triggered when initiating a clean shutdown from Linux.

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

This sets up the `OMEN Clean Shutdown` startup task (with forced process termination `/f`), disables Windows Fast Startup/Hibernation (`powercfg /h off`), prevents pre-login application launching, configures the `RealTimeIsUniversal` registry key so Windows treats the hardware clock as UTC, and creates an elevated **"Reboot to rEFInd"** desktop shortcut that instantly restarts Windows back into the rEFInd boot menu when double-clicked.

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

## Use & OMEN Button Shortcut Setup

### Automatic Setup (During Installation)

When running `sudo bash ./install-linux.sh`, the installer will attempt to auto-detect your OMEN / Copilot button:

1. The installer prompts: `Press Enter, then press the Copilot/AI button once within 8 seconds.`
2. Press **Enter** in your terminal, then immediately press the **OMEN key** on your laptop.
3. The script detects the key press and configures the shortcut automatically for **GNOME** or **KDE Plasma**.

### Manual Setup

If auto-detection fails or you prefer to configure it manually, bind your OMEN key (or custom hotkey) to launch:

```bash
/usr/local/bin/omen-clean-shutdown-launcher
```

#### On GNOME:
1. Open **Settings** → **Keyboard** → **Keyboard Shortcuts** (at the bottom).
2. Scroll to the bottom and click **Custom Shortcuts (+)**.
3. Set the fields to:
   - **Name:** `OMEN Clean Shutdown`
   - **Command:** `/usr/local/bin/omen-clean-shutdown-launcher`
   - **Shortcut:** Press the **OMEN key** (or desired key combination).

#### On KDE Plasma:
1. Open **System Settings** → **Shortcuts**.
2. Select **Custom Shortcuts** (or **Command/URL**).
3. Add a new Global Shortcut:
   - **Trigger:** Press the **OMEN key**.
   - **Action:** `/usr/local/bin/omen-clean-shutdown-launcher`

---

### Confirmation Dialog

When triggered via the OMEN key or shortcut, a popup dialog (`kdialog`, `zenity`, or `yad`) will ask for confirmation before initiating the shutdown process to prevent accidental keypresses.

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

## Self-Healing Bootloader Architecture

Both OS installers set up automated self-healing mechanisms to protect rEFInd:

- **Windows Self-Healing (`C:\omen-clean-shutdown.bat`)**: Runs as a `SYSTEM` startup task on every Windows boot (configured to run on both AC and Battery power).
  - Retries mounting the EFI partition up to 5 times (2 seconds apart) to handle early boot timing when the storage service is initializing.
  - Checks if a Windows Update overwrote `bootmgfw.efi` (file size > 1MB) and restores `refind_x64.efi`.
  - Checks if `refind.conf` has `timeout -1` left over from an interrupted shutdown and restores your configured timeout (or defaults to `timeout 0`).
  - Automatically heals and cleans up orphaned flag files or stuck timeouts on normal startup.

## Troubleshooting

### Windows Boots Directly into Windows (rEFInd Menu Skipped)

If restarting or powering on boots straight into Windows without showing the rEFInd menu:

1. **Disable Fast Startup & Hibernation**:
   - Fast Startup causes Windows to save kernel state to `hiberfil.sys` and bypass UEFI/rEFInd on boot.
   - Run PowerShell as Administrator and execute:
     ```powershell
     powercfg /h off
     ```
   - This removes `hiberfil.sys` and forces a true, clean shutdown so rEFInd loads every time.
2. **Re-run the Windows installer**:
   - Open PowerShell as Administrator and run `.\install-windows.ps1` to re-trigger self-healing and task updates.
3. **Verify BIOS / NVRAM Boot Order**:
   - In PowerShell (Admin), check your boot menu entries:
     ```powershell
     bcdedit /enum firmware
     ```
   - If needed, restore rEFInd as the primary boot manager manually:
     ```powershell
     bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst
     ```

### Windows Stays on Login / PIN Screen
- **Does a PIN code block shutdown?** No. The Windows task runs under the `SYSTEM` background account on startup before user login.
- **Testing the Windows Task:** You can manually verify that the Windows scheduled task is working by running this command in PowerShell (Admin) and then restarting:
  ```powershell
  mountvol B: /S; New-Item -Path "B:\EFI\refind\shutdown_flag" -ItemType File -Force; mountvol B: /D
  ```
  Upon rebooting into Windows, rEFInd will automatically hide its menu (`timeout -1`) and Windows will power down within 3 seconds at the PIN screen.

---

## Notes

- This is a workaround, not a firmware fix.
- **Battery Care / 80% Charge Limit:** HP's 80% battery limit / battery care mode in BIOS/OMEN Gaming Hub works cleanly alongside this workaround. The scheduled task is configured to run on both battery and AC power (`AllowStartIfOnBatteries`).
- **Timeout & Selection Preservation:** The shutdown script saves your current rEFInd menu timeout and default OS selection before temporarily setting `timeout -1` and `default_selection "Windows"` for the reboot, and restores both exact settings on the Windows side.
- **Windows Fast Startup & Hibernation Disabling (`hiberfil.sys`)**: Fast Startup and Hibernation are automatically disabled by `install-windows.ps1` (`powercfg /h off` and `HiberbootEnabled = 0`). Removing `hiberfil.sys` prevents Windows from skipping the rEFInd UEFI boot loader upon cold boot.
- **Pre-login App Launch Prevention**: The installer configures `UserDeviceSignIn = 0` to block Windows 10/11 from pre-loading user startup programs in the background before user logon. This ensures background services don't stall the automated 3-second shutdown window.
- **BTRFS Filesystem (CachyOS) & Windows Compatibility:** 
  - The shutdown workaround does **not** require any BTRFS drivers in Windows, as all cross-OS communication uses the standard FAT32 EFI System Partition (ESP).
  - If you wish to access your CachyOS BTRFS files directly from Windows for general file sharing, you can optionally install [WinBtrfs](https://github.com/maarmato/winbtrfs). 
  - *Caution:* When using WinBtrfs, ensure Windows Fast Startup (`powercfg /h off`) remains disabled to prevent filesystem dirty flags or corruption when switching between OSes.
- The OMEN AI/Copilot key usually appears as `XF86Launch2` on Linux, but the installer will try to detect `KEY_PROG1` through `KEY_PROG4` first.
- The EFI paths used here match the OMEN layout from the original guide; if your machine uses different paths, adjust the scripts or set the environment variables above.
- This workaround relies on rEFInd. It will not work with Limine, GRUB, or systemd-boot without significant changes.

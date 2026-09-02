# HP OMEN Linux Clean Shutdown Fix (Dual-Drive Setup)

This repo packages the HP OMEN shutdown workaround into two installers plus a few source files:

- `install-linux.sh` for Nobara/Fedora, CachyOS, Arch, and other systemd-based distros running on the secondary drive
- `install-windows.ps1` for Windows running on the primary drive
- `windows/omen-clean-shutdown.ps1`, `linux/omen-shutdown-diagnose.sh`, and `acpi/ssdt-omen-s5.asl` (template only)

The goal is simple: when you shut down from Linux, the laptop reboots into Windows first, Windows finishes the power-off correctly, and the machine ends up fully off.

This is a **workaround**, not an HP firmware fix. Recent OMEN 16 (especially **16-ap0xxx** with NVIDIA RTX 50-series) often never reach ACPI **S5** from Linux: systemd hits `poweroff.target` while the discrete GPU rail stays at roughly **15–19 W**, the chassis stays warm, and the battery drains. Kernel parameters (`acpi_osi`, `reboot=pci`, `reboot=efi`) do not restore S5. BIOS updates through F.13 have not either. Windows 11 on the same hardware typically does complete S5.

**Safety:** a black screen after Linux “Shut Down” is not proof of S5. Do not bag the laptop until the power LED is off and the chassis is cold.

## Dual-Drive Architecture

This setup is optimized for dual-disk laptop configurations:
- **Primary Drive (Disk 0)**: Windows 11 installation and primary UEFI System Partition (ESP) containing rEFInd / Windows Boot Manager.
- **Secondary Drive (Disk 1)**: Linux installation (Nobara/Fedora, Arch, CachyOS, etc.) with root `/` and swap/data partitions.

Having Linux on a secondary drive with Windows on the primary drive keeps drive management simple and isolates OS updates while sharing the primary EFI partition for rEFInd boot management.

## Video Demonstration

Watch the process in action showing the clean shutdown workaround operating on an HP OMEN dual-drive setup:

[![HP OMEN Linux Clean Shutdown Demonstration](https://img.youtube.com/vi/k8dsuiLzqBs/maxresdefault.jpg)](https://youtu.be/k8dsuiLzqBs)

*(Click thumbnail above or [watch on YouTube](https://youtu.be/k8dsuiLzqBs))*

## How it works

1. You trigger shutdown from Linux (OMEN AI/Copilot key, desktop Shut Down, `systemctl poweroff`, or the launcher). The installer intercepts `poweroff.target` / `halt.target` so the DE menu is included.
2. The Linux script saves the current rEFInd `default_selection` and `timeout`, sets `default_selection "Windows"` and `timeout -1` so rEFInd boots Windows immediately during the automated shutdown cycle.
3. The script creates a flag file on the shared EFI partition and reboots.
4. Windows starts from the primary drive. A scheduled task running as `SYSTEM` sees the flag, restores the saved rEFInd default and timeout (`timeout 0` for persistent interactive boot menu), deletes the flag, and shuts Windows down.
5. The laptop is now fully off. Next power-on boots back into the interactive rEFInd boot menu normally.

### Reboot & Boot Menu Behavior

* **rEFInd Menu Persistence (`timeout 0`)**: Setting/restoring `timeout 0` disables auto-boot timeouts, ensuring that the rEFInd graphical boot menu remains on screen indefinitely upon power-on or restart until an OS option is manually selected.
* **Standard Restarts**: Performing a standard **Restart** (from either Windows or Linux/CachyOS) will bring up the **rEFInd boot menu** normally and pause until you choose an OS. The automated Windows shutdown sequence is only triggered when initiating a clean shutdown from Linux.

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
| `install-linux.sh` | Set up the Linux side (secondary drive). Optional `--acpi-s5` copies an experimental SSDT template only. |
| `install-windows.ps1` | Set up the Windows side (primary drive) and fix the hardware clock timezone |
| `windows/omen-clean-shutdown.ps1` | Source for the Windows startup handler (copied to `C:\omen-clean-shutdown.ps1`) |
| `linux/omen-shutdown-diagnose.sh` | Source for the diagnose helper (copied to `/usr/local/bin/omen-shutdown-diagnose`) |
| `acpi/ssdt-omen-s5.asl` | **Experimental** S5-only SSDT template (`PG00._OFF` / PEGP `_PS3`). Copied with `--acpi-s5`; not loaded automatically. |
| `C:\omen-clean-shutdown.ps1` | Installed Windows startup handler (dynamic EFI discovery, logs under `%ProgramData%\omen-clean-shutdown\`) |
| `C:\omen-clean-shutdown.bat` | Thin wrapper that runs the `.ps1` |
| `/usr/local/bin/omen-clean-shutdown-launcher` | Linux shortcut target (shows a confirm dialog) |
| `/usr/local/bin/omen-clean-shutdown.sh` | Linux shutdown logic (writes EFI flag, then irreversible reboot into Windows) |
| `/usr/local/bin/omen-shutdown-diagnose` | Prints DSDT method names, ACPI errors, NVIDIA PCI power, last shutdown journal |
| `/usr/local/bin/refind-protect.sh` | Restores rEFInd if Windows overwrites the boot manager |

## Installation Guide

Do the Windows side first on your primary drive, then the Linux side on your secondary drive.

### 1. On Windows (Primary Drive - Disk 0)

Open PowerShell as Administrator in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

This copies `windows/omen-clean-shutdown.ps1` to `C:\omen-clean-shutdown.ps1` (the path the scheduled task actually runs), writes a thin `.bat` wrapper, disables Windows Fast Startup/Hibernation (`powercfg /h off`), prevents pre-login application launching, configures the `RealTimeIsUniversal` registry key so Windows treats the hardware clock as UTC, and creates an elevated **"Reboot to rEFInd"** desktop shortcut. Logs go to `%ProgramData%\omen-clean-shutdown\omen-clean-shutdown.log`.

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

Optional (does **not** replace the Windows reboot path; only installs a template):

```bash
sudo bash ./install-linux.sh --acpi-s5
```

If the script lives on a mounted Windows drive/partition, run it from that clone, for example:

```bash
cd /mnt/windows/Users/<you>/.../hp-omen-linux-shutdown-fix
sudo bash ./install-linux.sh
```

Re-run `install-windows.ps1` after pulling this repo so `C:\omen-clean-shutdown.ps1` matches the source file (older installs only wrote a `.bat`).

### Escape hatch

To use a native Linux poweroff (firmware S5, which may leave the dGPU rail on):

```bash
sudo touch /etc/omen-native-poweroff
```

Remove that file to restore the Windows-reboot intercept.

Logs: `/var/log/omen-clean-shutdown.log`. Diagnose: `sudo omen-shutdown-diagnose`.

## Use & OMEN Button Shortcut Setup

### Automatic Setup (During Installation)

When running `sudo bash ./install-linux.sh`, the installer will attempt to auto-detect your OMEN / Copilot button:

1. The installer prompts: `Press Enter, then press the Copilot/AI button once within 8 seconds.`
2. Press **Enter** in your terminal, then immediately press the **OMEN key** on your laptop.
3. The script detects the key press and configures the shortcut automatically for **GNOME** or **KDE Plasma**. On GNOME it appends a free `customN` slot and does not overwrite `custom0`.

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

When triggered via the OMEN key or the launcher, a popup dialog (`kdialog`, `zenity`, or `yad`) will ask for confirmation. Desktop **Shut Down** / `systemctl poweroff` skip that dialog and go straight through the `poweroff.target` intercept.

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
| `RESTORE_FILE` | `$EFI_MOUNT/EFI/refind/default_selection_restore` | Saved rEFInd default selection (timeout is saved as `${RESTORE_FILE}_timeout`) |

## Self-Healing Bootloader Architecture

Both OS installers set up automated self-healing mechanisms to protect rEFInd:

- **Windows Self-Healing (`C:\omen-clean-shutdown.ps1`)**: Runs as a `SYSTEM` startup task on every Windows boot (configured to run on both AC and Battery power).
  - Dynamically detects the EFI System Partition containing `refind.conf` across pre-mounted drive letters (e.g. `S:`) before attempting temporary `B:` mounting.
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

## Experimental native S5 (optional)

Do not ship or load a precompiled AML for every OMEN. Tables differ by board and BIOS.

On some 16-ap0xxx units the dGPU rail is ACPI power resource `PG00` on `\_SB.PCI0.GPP0`. Firmware `PG00._OFF` works but Linux never calls it at S5 (`pci_device_shutdown` can even power the rail back up). Other units abort `_SB.WMID.WQBZ` with `AE_AML_BUFFER_LIMIT` so PEGP never reaches `_PS3`.

`acpi/ssdt-omen-s5.asl` is a **template** that calls PEGP `_PS3` and `PG00._OFF` from `_PTS(5)` if those objects exist. Compile with `iasl` only after you dump **your** DSDT and confirm the paths. Load it as a **second** bootloader entry (Limine/mkinitcpio `acpi_override` or dracut acpi hook). Keep the stock kernel entry and keep this repo’s Windows-reboot path until the power LED goes off and the chassis is cold.

A more complete experimental toolkit (S5-only vs Combined WQBZ bounding), validated on a specific board/BIOS, is [OMEN ACPI Toolkit](https://github.com/paolo-de-marinis/omen-acpi) (current release [v2.4.0](https://github.com/paolo-de-marinis/omen-acpi/releases/tag/v2.4.0); CachyOS + Limine, physically checked on OMEN MAX 16-ap0006sl board 8E35 / BIOS F.13).

BIOS **integrated-GPU only** can also reach a real off state on some units (you lose the dGPU). Userspace `acpi_call` `_OFF` is not enough.

Related issues that are **not** this bug: `nvidia_drm modeset=1 fbdev=0` (fbcon deadlock); HP SoftPaq SP152972 (Windows 11 hang after NVIDIA 572.40 on 16-wd/wf).

## Limine / GRUB / systemd-boot

The automated flag + `refind.conf` rewrite still requires **rEFInd**. CachyOS often defaults to Limine. Until Limine/GRUB one-shot Windows boot is implemented here, install rEFInd on the primary ESP as documented, or use [omen-acpi](https://github.com/paolo-de-marinis/omen-acpi) experimental entries on Limine.

## Notes

- This is a workaround, not a firmware fix. Sources: [Arch BBS](https://bbs.archlinux.org/viewtopic.php?id=313030), [Fedora](https://discussion.fedoraproject.org/t/technical-issue-incomplete-shutdown-on-hp-omen-16-ap0038ns/184041), [CachyOS](https://discuss.cachyos.org/t/technical-issue-incomplete-shutdown-on-hp-omen-16-ap0038ns/26236), [NVIDIA forum](https://forums.developer.nvidia.com/t/hp-omen-16-rtx-5060-battery-drains-after-shutdown-on-linux-gps-acpi-dsm-bug/364074), [HP Community](https://h30434.www3.hp.com/t5/Gaming-Notebooks/After-shuting-down-from-a-Linux-distribution-HP-OMEN-16/td-p/9624996).
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

# HP OMEN Linux Clean Shutdown Fix (Dual-Drive Setup)

This repo packages the HP OMEN shutdown workaround into two installers plus a few source files:

- `install-linux.sh` for Nobara/Fedora, CachyOS, Arch, and other systemd-based distros running on the secondary drive
- `install-windows.ps1` for Windows running on the primary drive
- `windows/omen-clean-shutdown.ps1`, `linux/omen-clean-shutdown.sh`, `linux/omen-boot-lib.sh`, `linux/omen-shutdown-diagnose.sh`, and `acpi/ssdt-omen-s5.asl` (template only)

The goal is simple: when you shut down from Linux, the laptop reboots into Windows first, Windows finishes the power-off correctly, and the machine ends up fully off.

This is a **workaround**, not an HP firmware fix. Recent OMEN 16 (especially **16-ap0xxx** with NVIDIA RTX 50-series) often never reach ACPI **S5** from Linux: systemd hits `poweroff.target` while the discrete GPU rail stays at roughly **15–19 W**, the chassis stays warm, and the battery drains. Kernel parameters (`acpi_osi`, `reboot=pci`, `reboot=efi`) do not restore S5. BIOS updates through F.13 have not either. Windows 11 on the same hardware typically does complete S5.

**Safety:** a black screen after Linux “Shut Down” is not proof of S5. Do not bag the laptop until the power LED is off and the chassis is cold.

## Dual-Drive Architecture

This setup is optimized for dual-disk laptop configurations:
- **Primary Drive (Disk 0)**: Windows 11 installation and the Windows EFI System Partition (`bootmgfw.efi`).
- **Secondary Drive (Disk 1)**: Linux installation (Nobara/Fedora, Arch, CachyOS, etc.) with root `/` (often Btrfs) and its own bootloader (Limine, GRUB, rEFInd, or systemd-boot).

Having Linux on a secondary drive keeps OS updates isolated. The shutdown flag is always written to the **Windows ESP** (FAT32) so Windows can see it even when Linux `/boot` is Btrfs.

## Video Demonstration

Watch the process in action showing the clean shutdown workaround operating on an HP OMEN dual-drive setup:

[![HP OMEN Linux Clean Shutdown Demonstration](https://img.youtube.com/vi/k8dsuiLzqBs/maxresdefault.jpg)](https://youtu.be/k8dsuiLzqBs)

*(Click thumbnail above or [watch on YouTube](https://youtu.be/k8dsuiLzqBs))*

## How it works

1. You trigger shutdown from Linux (OMEN AI/Copilot key, desktop Shut Down, `systemctl poweroff`, or the launcher). The installer intercepts `poweroff.target` / `halt.target` so the DE menu is included.
2. The Linux script writes `EFI/omen/shutdown_flag` on the **Windows** ESP (FAT32). That path works with Limine, GRUB, rEFInd, and Btrfs `/boot` because Windows never has to read the Linux filesystem.
3. It then forces the next firmware boot into Windows Boot Manager (`efibootmgr --bootnext`). Firmware clears `BootNext` after that one boot. rEFInd setups still rewrite `refind.conf` as before (`default_selection "Windows"`, `timeout -1`).
4. Windows starts from the primary drive. A scheduled task running as `SYSTEM` sees the flag, deletes it (and restores rEFInd settings if present), and shuts Windows down.
5. The laptop is now fully off. Next power-on uses the normal firmware boot order (Limine / GRUB / rEFInd).

### Reboot & Boot Menu Behavior

* **Standard Restarts**: A normal **Restart** from either OS does **not** set `BootNext` or the shutdown flag. You get your usual boot menu (Limine, GRUB, or rEFInd).
* **rEFInd Menu Persistence (`timeout 0`)**: On rEFInd installs, restoring `timeout 0` keeps the graphical menu on screen until you pick an OS.
* **Btrfs**: CachyOS can keep `/` and `/boot` on Btrfs. The workaround does not write Limine/GRUB config on Btrfs (GRUB cannot reliably clear `grubenv` there, which would loop into Windows).

## Requirements

- UEFI firmware (Secure Boot can stay on for Limine/GRUB if the distro supports it; rEFInd-on-`bootmgfw` setups still need it off)
- Dual-drive setup: Windows on **Primary Drive (Disk 0)**, Linux on **Secondary Drive (Disk 1)**
- A Linux boot manager the installer can detect: **Limine**, **GRUB**, **rEFInd**, or **systemd-boot**
- Linux using **systemd**
- `efibootmgr` available (used to set one-shot `BootNext` to Windows)

## Supported Linux distros

- Nobara / Fedora (typically GRUB)
- CachyOS (typically Limine + Btrfs)
- Arch Linux
- Other systemd-based distros (may require `BOOTLOADER=` / `WINDOWS_BOOTNUM=` overrides)

The installer auto-detects Limine (`/boot/limine.conf`), GRUB (`/boot/grub/grub.cfg` or `/boot/grub2/grub.cfg`), rEFInd, and systemd-boot. It prefers firmware `BootNext` so it does not depend on rewriting a Btrfs `/boot`.

## Files

| File | Purpose |
|---|---|
| `install-linux.sh` | Set up the Linux side (secondary drive). Optional `--acpi-s5` copies an experimental SSDT template only. |
| `install-windows.ps1` | Set up the Windows side (primary drive) and fix the hardware clock timezone |
| `windows/omen-clean-shutdown.ps1` | Source for the Windows startup handler (copied to `C:\omen-clean-shutdown.ps1`) |
| `linux/omen-boot-lib.sh` | Shared Limine/GRUB/rEFInd/ESP detection (installed under `/usr/local/lib/omen-clean-shutdown/`) |
| `linux/omen-clean-shutdown.sh` | Linux shutdown logic (ESP flag + BootNext / rEFInd rewrite) |
| `linux/refind-protect.sh` | Restores rEFInd if Windows overwrites `bootmgfw.efi` (enabled only when rEFInd is detected) |
| `linux/omen-shutdown-diagnose.sh` | Source for the diagnose helper (copied to `/usr/local/bin/omen-shutdown-diagnose`) |
| `acpi/ssdt-omen-s5.asl` | **Experimental** S5-only SSDT template (`PG00._OFF` / PEGP `_PS3`). Copied with `--acpi-s5`; not loaded automatically. |
| `C:\omen-clean-shutdown.ps1` | Installed Windows startup handler (looks for `EFI\omen\shutdown_flag`, logs under `%ProgramData%\omen-clean-shutdown\`) |
| `C:\omen-clean-shutdown.bat` | Thin wrapper that runs the `.ps1` |
| `/etc/omen-clean-shutdown.env` | Detected bootloader, Windows ESP, BootNext id |
| `/usr/local/bin/omen-clean-shutdown-launcher` | Linux shortcut target (shows a confirm dialog) |
| `/usr/local/bin/omen-clean-shutdown.sh` | Installed Linux shutdown logic |
| `/usr/local/bin/omen-shutdown-diagnose` | Prints DSDT method names, ACPI errors, NVIDIA PCI power, bootloader, last shutdown journal |
| `/usr/local/bin/refind-protect.sh` | Restores rEFInd if Windows overwrites the boot manager |

## Installation Guide

Do the Windows side first on your primary drive, then the Linux side on your secondary drive.

### 1. On Windows (Primary Drive - Disk 0)

Open PowerShell as Administrator in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

This copies `windows/omen-clean-shutdown.ps1` to `C:\omen-clean-shutdown.ps1` (the path the scheduled task actually runs), writes a thin `.bat` wrapper, disables Windows Fast Startup/Hibernation (`powercfg /h off`), prevents pre-login application launching, configures the `RealTimeIsUniversal` registry key so Windows treats the hardware clock as UTC, and creates an elevated **"Reboot to Linux boot manager"** desktop shortcut (Limine, GRUB, or rEFInd). Logs go to `%ProgramData%\omen-clean-shutdown\omen-clean-shutdown.log`.

### 2. On Linux (Secondary Drive - Disk 1)

CachyOS with Limine (default) and Fedora/Nobara with GRUB do **not** need rEFInd. Optional, only if you want the rEFInd menu:

```bash
# CachyOS / Arch
sudo pacman -S refind
sudo refind-install

# Nobara / Fedora
sudo dnf install refind
sudo refind-install
```

Then run the Linux installer. It detects Limine, GRUB, or rEFInd and mounts the Windows ESP to place `EFI/omen/shutdown_flag`.

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
| `BOOTLOADER` | auto (`limine` / `grub` / `refind` / `systemd-boot`) | Force a backend |
| `WINDOWS_ESP_DEV` | auto (ESP that contains `bootmgfw.efi`) | Windows EFI partition device |
| `WINDOWS_BOOTNUM` | auto (`efibootmgr`) | Four-digit Windows Boot Manager id for `BootNext` |
| `ONESHOT_METHOD` | auto (`bootnext`, `refind-conf`, `loader-oneshot`, `grub-reboot`) | How to force the next boot into Windows |
| `EFI_MOUNT` | `/boot/efi`, `/efi`, or `/boot` | Linux ESP / XBOOTLDR mount |
| `LIMINE_CONF` | auto-detected | Path to `limine.conf` / `limine.cfg` |
| `GRUB_CFG` | auto-detected | Path to `grub.cfg` |
| `REFIND_CONF` | auto-detected | Path to `refind.conf` |
| `REFIND_SOURCE` | auto-detected | Path to `refind_x64.efi` |
| `REFIND_TARGET` | `$EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi` | Where to restore rEFInd if Windows overwrites it |
| `FLAG_FILE` | `$WINDOWS_ESP/EFI/omen/shutdown_flag` | Flag file that tells Windows to finish shutdown |
| `RESTORE_FILE` | next to `refind.conf` | Saved rEFInd default selection (timeout is saved as `${RESTORE_FILE}_timeout`) |

## Self-Healing Bootloader Architecture

- **Windows handler (`C:\omen-clean-shutdown.ps1`)**: Runs as a `SYSTEM` startup task on every Windows boot (AC and battery).
  - Looks for `EFI\omen\shutdown_flag` (Limine/GRUB/Btrfs) then the legacy `EFI\refind\shutdown_flag`.
  - Mounts the Windows ESP with `mountvol B: /S` if needed.
  - If rEFInd files are present: restores `refind.conf` and optionally copies `refind_x64.efi` back over a large `bootmgfw.efi` after a Windows update.
- **Linux `BootNext`**: Firmware one-shot. After Windows powers off, the next cold boot uses your normal Limine/GRUB/rEFInd entry. Windows updates that reorder NVRAM are repaired on the next Linux shutdown (the script re-reads `efibootmgr`).
- **rEFInd protect service**: Enabled only when rEFInd is detected.

## Troubleshooting

### Windows Boots Directly into Windows (Linux menu skipped)

If restarting or powering on boots straight into Windows without showing Limine, GRUB, or rEFInd:

1. **Disable Fast Startup & Hibernation**:
   - Fast Startup causes Windows to save kernel state to `hiberfil.sys` and bypass the Linux UEFI boot manager.
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
   - If needed, put the Linux boot manager first in firmware boot order (or use the **Reboot to Linux boot manager** shortcut). From Linux: `sudo efibootmgr -o <limine-or-grub>,<windows>`.

### Shutdown from Linux does not reboot into Windows, then power off

The workaround is: Linux writes `EFI/omen/shutdown_flag` on the **Windows** ESP, sets firmware `BootNext` to Windows Boot Manager, **reboots** (not poweroff), Windows sees the flag and issues a real S5 shutdown.

If that hop never happens, re-run both installers (the Linux unit file and Windows handler must be updated) and check:

1. **Linux log** `/var/log/omen-clean-shutdown.log` — you should see `flag written` and `rebooting into Windows`. If you see `failed to set one-shot Windows boot` or `failed to mount Windows ESP`, `BootNext` never stuck or the flag went to the wrong disk.
2. **`sudo omen-shutdown-diagnose`** — confirm `windows ESP` is the Disk 0 FAT32 partition that contains `bootmgfw.efi`, and `windows bootnum` matches `efibootmgr`.
3. **Windows log** `%ProgramData%\omen-clean-shutdown\omen-clean-shutdown.log` — on the Windows hop it should say `shutdown_flag present` then power off. `Normal startup; no shutdown flag` means Linux wrote the flag on the Linux ESP, or the Windows task ran before the ESP was visible (the handler now scans every GPT ESP).
4. **Do not use** `sudo touch /etc/omen-native-poweroff` unless you want a native Linux poweroff (that path skips Windows and often leaves the dGPU rail on).

Known causes this repo now guards against:

- systemd deadlocking because `omen-clean-shutdown.service` used to `Conflicts=reboot.target` while converting poweroff into reboot
- HP firmware ignoring `BootNext` on an ACPI reset (the script now prefers `/sys/kernel/reboot/mode = efi`)
- Dual-drive setups writing the flag to the Linux ESP (Windows never sees it)
- The Windows handler aborting on empty CD/card-reader drive letters, or only looking at `mountvol /S` (the firmware ESP is the Linux one if Windows was chainloaded)

### Windows Stays on Login / PIN Screen
- **Does a PIN code block shutdown?** No. The Windows task runs under the `SYSTEM` background account on startup before user login. A second AtLogOn trigger is a fallback if the boot trigger is delayed.
- **Testing the Windows Task:** You can manually verify that the Windows scheduled task is working by running this command in PowerShell (Admin) and then restarting:
  ```powershell
  mountvol B: /S; New-Item -Path "B:\EFI\omen\shutdown_flag" -ItemType File -Force; mountvol B: /D
  ```
  Upon rebooting into Windows, the startup task sees the flag and Windows powers down within a few seconds at the PIN screen.

---

## Experimental native S5 (optional)

Do not ship or load a precompiled AML for every OMEN. Tables differ by board and BIOS.

On some 16-ap0xxx units the dGPU rail is ACPI power resource `PG00` on `\_SB.PCI0.GPP0`. Firmware `PG00._OFF` works but Linux never calls it at S5 (`pci_device_shutdown` can even power the rail back up). Other units abort `_SB.WMID.WQBZ` with `AE_AML_BUFFER_LIMIT` so PEGP never reaches `_PS3`.

`acpi/ssdt-omen-s5.asl` is a **template** that calls PEGP `_PS3` and `PG00._OFF` from `_PTS(5)` if those objects exist. Compile with `iasl` only after you dump **your** DSDT and confirm the paths. Load it as a **second** bootloader entry (Limine/mkinitcpio `acpi_override` or dracut acpi hook). Keep the stock kernel entry and keep this repo’s Windows-reboot path until the power LED goes off and the chassis is cold.

A more complete experimental toolkit (S5-only vs Combined WQBZ bounding), validated on a specific board/BIOS, is [OMEN ACPI Toolkit](https://github.com/paolo-de-marinis/omen-acpi) (current release [v2.4.0](https://github.com/paolo-de-marinis/omen-acpi/releases/tag/v2.4.0); CachyOS + Limine, physically checked on OMEN MAX 16-ap0006sl board 8E35 / BIOS F.13).

BIOS **integrated-GPU only** can also reach a real off state on some units (you lose the dGPU). Userspace `acpi_call` `_OFF` is not enough.

Related issues that are **not** this bug: `nvidia_drm modeset=1 fbdev=0` (fbcon deadlock); HP SoftPaq SP152972 (Windows 11 hang after NVIDIA 572.40 on 16-wd/wf).

## Limine / GRUB / systemd-boot / Btrfs

Supported. The installer picks a backend:

| Bootloader | One-shot Windows boot | Notes |
|---|---|---|
| **Limine** (CachyOS default) | `efibootmgr --bootnext` (firmware). Fallback: `bootctl set-oneshot` (`LoaderEntryOneShot`) | Does **not** rewrite `/boot/limine.conf` (often on Btrfs; `limine-update` regenerates it) |
| **GRUB** | `BootNext`. `grub-reboot` only if `grubenv` is on FAT/ext4 | **Never** `grub-reboot` when `/boot` is Btrfs — GRUB cannot clear `next_entry` and you loop into Windows |
| **rEFInd** | Rewrite `refind.conf` (`timeout -1`, `default_selection "Windows"`), plus `BootNext` if Windows Boot Manager is a real entry | Existing OMEN layout |
| **systemd-boot** | `BootNext` or `bootctl set-oneshot windows` | Same flag path |

Keep Limine/GRUB/rEFInd as firmware **BootOrder #1**. `BootNext` is one-shot and does not permanently promote Windows.

If BitLocker is on, `BootNext` to Windows Boot Manager is the safe path (clean TPM PCR 7). Chainloading `bootmgfw.efi` from Limine `protocol: efi` can demand the recovery key; prefer `protocol: efi_boot_entry` for the Limine *menu* entry, and still use `BootNext` for this shutdown workaround.

## Notes

- This is a workaround, not a firmware fix. Sources: [Arch BBS](https://bbs.archlinux.org/viewtopic.php?id=313030), [Fedora](https://discussion.fedoraproject.org/t/technical-issue-incomplete-shutdown-on-hp-omen-16-ap0038ns/184041), [CachyOS](https://discuss.cachyos.org/t/technical-issue-incomplete-shutdown-on-hp-omen-16-ap0038ns/26236), [NVIDIA forum](https://forums.developer.nvidia.com/t/hp-omen-16-rtx-5060-battery-drains-after-shutdown-on-linux-gps-acpi-dsm-bug/364074), [HP Community](https://h30434.www3.hp.com/t5/Gaming-Notebooks/After-shuting-down-from-a-Linux-distribution-HP-OMEN-16/td-p/9624996).
- **Battery Care / 80% Charge Limit:** HP's 80% battery limit / battery care mode in BIOS/OMEN Gaming Hub works cleanly alongside this workaround. The scheduled task is configured to run on both battery and AC power (`AllowStartIfOnBatteries`).
- **Timeout & Selection Preservation:** On rEFInd, the shutdown script saves menu timeout and default OS selection, then restores them on the Windows side. Limine/GRUB use firmware `BootNext` instead, so no config restore is required.
- **Windows Fast Startup & Hibernation Disabling (`hiberfil.sys`)**: Fast Startup and Hibernation are automatically disabled by `install-windows.ps1` (`powercfg /h off` and `HiberbootEnabled = 0`). Removing `hiberfil.sys` prevents Windows from skipping Limine/GRUB/rEFInd on cold boot.
- **Pre-login App Launch Prevention**: The installer configures `UserDeviceSignIn = 0` to block Windows 10/11 from pre-loading user startup programs in the background before user logon. This ensures background services don't stall the automated 3-second shutdown window.
- **BTRFS Filesystem (CachyOS) & Windows Compatibility:** 
  - The shutdown workaround does **not** require any BTRFS drivers in Windows, as all cross-OS communication uses the standard FAT32 EFI System Partition (ESP).
  - If you wish to access your CachyOS BTRFS files directly from Windows for general file sharing, you can optionally install [WinBtrfs](https://github.com/maarmato/winbtrfs). 
  - *Caution:* When using WinBtrfs, ensure Windows Fast Startup (`powercfg /h off`) remains disabled to prevent filesystem dirty flags or corruption when switching between OSes.
- The OMEN AI/Copilot key usually appears as `XF86Launch2` on Linux, but the installer will try to detect `KEY_PROG1` through `KEY_PROG4` first.
- The EFI flag path is `EFI/omen/shutdown_flag` on the Windows ESP. Override with `WINDOWS_ESP_DEV` / `FLAG_FILE` if your firmware layout differs.

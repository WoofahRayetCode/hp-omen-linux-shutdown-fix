# HP OMEN Linux Clean Shutdown Fix

This repo packages the HP OMEN shutdown workaround into two scripts:

- `install-linux.sh` for Nobara/Fedora, CachyOS, Arch, and other systemd-based distros
- `install-windows.ps1` for Windows

The goal is simple: when you shut down from Linux, the laptop reboots into Windows first, Windows finishes the power-off correctly, and the machine ends up fully off.

## Why this exists

Some HP OMEN laptops do not fully power off when Linux shuts down. The screen goes dark, but the machine may stay warm or keep draining battery. Windows shuts down normally, so this workaround uses Windows as the final step.

## How it works

1. You trigger the shutdown from Linux (OMEN AI/Copilot key, shortcut, or terminal).
2. The Linux script saves the current rEFInd `default_selection`, sets it to `"Windows"`, and sets `timeout -1` so rEFInd boots Windows immediately.
3. The script creates a flag file on the EFI partition and reboots.
4. Windows starts. A scheduled task running as `SYSTEM` sees the flag, restores the saved rEFInd default, deletes the flag, and shuts Windows down.
5. The laptop is now fully off. Next power-on boots back into Linux normally.

## Requirements

- UEFI firmware with **Secure Boot disabled**
- **rEFInd** installed as the boot manager
- Linux using **systemd**
- Windows on the same machine

## Supported Linux distros

- Nobara / Fedora
- CachyOS
- Arch Linux
- Other systemd-based distros with rEFInd (may require small tweaks)

The Linux installer auto-detects the rEFInd binary path used by Fedora/Nobara (`/usr/share/rEFInd/refind/refind_x64.efi`) and Arch/CachyOS (`/usr/share/refind/refind_x64.efi`).

## Files

| File | Purpose |
|---|---|
| `install-linux.sh` | Set up the Linux side |
| `install-windows.ps1` | Set up the Windows side and fix the hardware clock timezone |
| `autounattend.xml` | Unattended Windows install with 2 GB EFI partition |
| `C:\omen-clean-shutdown.bat` | Windows startup handler |
| `/usr/local/bin/omen-clean-shutdown-launcher` | Linux shortcut target |
| `/usr/local/bin/omen-clean-shutdown.sh` | Linux shutdown logic |
| `/usr/local/bin/refind-protect.sh` | Restores rEFInd if Windows overwrites the boot manager |

## Clean Windows install with a 2 GB EFI partition (optional)

Some Linux installers (including CachyOS) warn or fail if the EFI system partition is smaller than 2048 MB. A fresh Windows install is the cleanest way to create a 2 GB EFI partition.

This repo includes `autounattend.xml` for an unattended Windows 11 IoT Enterprise LTSC install with:

- **2048 MB EFI partition**
- **16 MB MSR partition**
- **50 GB Windows partition**
- Rest of the disk left unallocated for Linux
- Built-in Administrator account enabled
- OOBE, privacy, and online account prompts skipped

### Using it with Ventoy

1. Get a legitimate **Windows 11 IoT Enterprise LTSC** ISO.
2. Copy the ISO, `autounattend.xml`, and the setup scripts to the root of your Ventoy data partition.

   Files to place on Ventoy:
   - `en-us_windows_11_iot_enterprise_ltsc_2024_x64_dvd_f6b14814.iso` (or your LTSC ISO)
   - `cachyos-desktop-linux-260628.iso` (or your preferred Linux ISO)
   - `autounattend.xml`
   - `install-windows.ps1`
   - `install-linux.sh`
   - `README.md`

3. Boot the Ventoy USB and select the Windows ISO.
4. Ventoy will automatically use `autounattend.xml` and install Windows with the partition layout above.
5. After Windows boots, run `install-windows.ps1` as Administrator from the Ventoy drive.
6. After installing Linux, run `sudo bash install-linux.sh` from the Ventoy drive.

The default Administrator password in the file is `password`. Edit `autounattend.xml` before using it.

## Install

Do the Windows side first, then the Linux side. That lets you verify the startup task before you wire the Linux shortcut.

### 1. On Windows

Open PowerShell as Administrator in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

This also sets the `RealTimeIsUniversal` registry key so Windows treats the hardware clock as UTC, preventing the common Windows/Linux time mismatch after dual-booting.

### 2. On Linux

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

If the script lives on a mounted Windows drive, you can run it from there:

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

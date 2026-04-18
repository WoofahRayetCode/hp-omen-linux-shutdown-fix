# HP OMEN Linux Clean Shutdown Fix (via rEFInd + Windows)

> **Device:** HP OMEN 16 (also applicable to Lenovo, ASUS Gaming series with similar ACPI issues)
> **Boot Manager:** rEFInd
> **Linux Distro:** Fedora (applies to any Linux distro on this hardware)

---

## 📋 Table of Contents

- [The Problem](#the-problem)
- [Root Cause](#root-cause)
- [The Solution](#the-solution)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Implementation](#implementation)
  - [Phase 1: Windows Side](#phase-1-windows-side)
  - [Phase 2: Linux Side](#phase-2-linux-side)
- [Full Flow Diagram](#full-flow-diagram)
- [rEFInd Auto-Restore Service](#refind-auto-restore-service)
- [Hide GRUB Menu](#hide-grub-menu-optional)
- [Troubleshooting](#troubleshooting)
- [Reverting Everything](#reverting-everything)
- [Why efibootmgr Doesn't Work](#why-efibootmgr-doesnt-work)

---

## The Problem

On HP OMEN 16 (and similar gaming laptops), shutting down from Linux does not fully power off the hardware. Specifically:

- The shutdown animation completes and the screen goes dark
- But the **GPU, fans, and background processes keep running**
- The system stays in a half-on state, generating heat silently
- This is because Linux triggers **ACPI S3** (suspend) instead of **ACPI S5** (full power off)
- Windows shuts down cleanly (S5 works fine from Windows)
- This affects **all Linux distributions** on this hardware — not just Fedora

---

## Root Cause

HP OMEN's firmware has a known ACPI implementation issue where the `shutdown` syscall from Linux does not correctly trigger the S5 power state. This is a hardware/firmware-level problem that cannot be fixed from Linux alone.

Additionally, HP OMEN (and many gaming laptops from HP, Lenovo, ASUS) have **firmware-level EFI boot entry protection**, which means:
- Tools like `efibootmgr` cannot reliably create persistent boot entries
- `BootNext` EFI variable is often ignored or cleared by the firmware
- Any "unknown" EFI entries get deleted on every boot

---

## The Solution

Since Windows shuts down cleanly (S5), we route the shutdown **through Windows**:

1. A **special key** (the AI button / `KEY_PROG2`) is bound to a script
2. The script modifies `refind.conf` to instantly boot Windows and creates a **flag file** on the EFI partition
3. On Windows startup, a **SYSTEM-level task** checks for the flag file
4. If flag exists → restore `refind.conf` + delete flag + shut down cleanly
5. If no flag → do nothing (normal Windows use is unaffected)

---

## How It Works

```
[Special Key Pressed from Fedora]
          ↓
Linux script runs:
  - Modifies refind.conf → timeout -1, default_selection "Windows"
  - Creates flag file at /boot/efi/EFI/refind/shutdown_flag
  - Reboots system
          ↓
rEFInd reads modified config → instantly boots Windows (no menu shown)
          ↓
Windows boots → SYSTEM task runs at startup (before login screen)
          ↓
    ┌─────────────────────────────────┐
    │  Flag file exists?              │
    │  YES → Delete flag              │
    │      → Restore refind.conf      │
    │        (timeout 10, Fedora)     │
    │      → Shutdown /s /t 5         │
    │  NO  → Do nothing               │
    │        (normal Windows session) │
    └─────────────────────────────────┘
          ↓
Clean S5 power off ✅
Next boot: rEFInd shows normally, Fedora is default ✅
```

---

## Prerequisites

- rEFInd boot manager installed and working
- Dual boot: Linux (Fedora) + Windows
- EFI partition mounted at `/boot/efi`
- `refind.conf` located (find it with: `find /boot/efi -name "refind.conf"`)
- The special key identified (AI button = `KEY_PROG2`, keycode 149)
- GNOME desktop environment

### Verify Your Setup

```bash
# Find your refind.conf location
find /boot/efi -name "refind.conf"

# Find your special key keycode
sudo libinput debug-events
# Press the key and note the keycode

# Check EFI partition
findmnt /boot/efi

# Check your username
whoami
```

---

## Implementation

> ⚠️ **Important:** Set up the **Windows side first**, verify it works, then set up the Linux side. This prevents getting locked out.

---

### Phase 1: Windows Side

Boot into Windows normally from rEFInd. Once on the desktop:

#### Step 1 — Create the Batch Script

1. Press `Win` → search **Notepad** → **Right click → Run as administrator**
2. Paste the following content:

```bat
@echo off
mountvol B: /S
if exist "B:\EFI\refind\shutdown_flag" (
    del "B:\EFI\refind\shutdown_flag"
    powershell -Command "(Get-Content 'B:\EFI\Microsoft\Boot\refind.conf') -replace 'timeout -1','timeout 10' -replace 'default_selection .Windows.','default_selection \"Fedora\"' | Set-Content 'B:\EFI\Microsoft\Boot\refind.conf'"
    mountvol B: /D
    shutdown /s /t 5
) else (
    mountvol B: /D
)
```

> ⚠️ **Important:** The `-replace 'default_selection .Windows.'` uses regex dots instead of literal quotes. This avoids PowerShell quote escaping issues that cause `default_selection "Fedora"` to be written as `default_selection Fedora"` (missing opening quote), which breaks rEFInd.

3. Save as `C:\shutdown_check.bat`
   - File → Save As
   - Location: `C:\`
   - Filename: `shutdown_check.bat`
   - Save as type: **All Files (\*.\*)** ← Important!

#### Step 2 — Verify the Batch Script

Open File Explorer → go to `C:\` → confirm `shutdown_check.bat` exists.

#### Step 3 — Create Task Scheduler Task

1. Press `Win + R` → type `taskschd.msc` → Enter
2. In right panel, click **"Create Task"** (NOT "Create Basic Task")

**General tab:**
- Name: `Linux Shutdown Task`
- ✅ Check **"Run with highest privileges"**
- Click **"Change User or Group"** → type `SYSTEM` → click **Check Names** → click OK
  - Should show `NT AUTHORITY\SYSTEM`

**Triggers tab:**
- Click **New**
- Begin the task: **"At startup"**
- Click OK

**Actions tab:**
- Click **New**
- Action: **"Start a program"**
- Program/script: `C:\shutdown_check.bat`
- Click OK

**Conditions tab:**
- ❌ Uncheck **"Start the task only if the computer is on AC power"**

Click **OK** to save.

#### Step 4 — Verify Task in PowerShell

Open **PowerShell as Administrator** and run:

```powershell
# Verify task exists
Get-ScheduledTask -TaskName "Linux Shutdown Task" | Select-Object TaskName, State

# Verify it runs as SYSTEM
Get-ScheduledTask -TaskName "Linux Shutdown Task" | Select-Object -ExpandProperty Principal

# Verify trigger is At Startup (should show MSFT_TaskBootTrigger)
(Get-ScheduledTask -TaskName "Linux Shutdown Task").Triggers.CimClass.CimClassName
```

Expected outputs:
```
TaskName             State
--------             -----
Linux Shutdown Task  Ready

UserId    : SYSTEM
RunLevel  : Highest

MSFT_TaskBootTrigger
```

#### Step 5 — Test Windows Side (Dry Run)

In PowerShell as Administrator, create a fake flag and test the script:

```powershell
# Create fake flag file
mountvol B: /S
echo test > "B:\EFI\refind\shutdown_flag"
mountvol B: /D

# Run the bat manually
C:\shutdown_check.bat
```

If it starts shutting down, **immediately run** `shutdown /a` to cancel.

If it ran correctly, the flag file will be gone and `refind.conf` will be restored.

✅ Windows side is ready. Boot back into Fedora normally.

---

### Phase 2: Linux Side

Boot into Fedora normally from rEFInd.

#### Step 1 — Create the Script

```bash
sudo -i

cat > /usr/local/bin/win-shutdown.sh << 'EOF'
#!/bin/bash

REFIND_CONF="/boot/efi/EFI/Microsoft/Boot/refind.conf"
FLAG_FILE="/boot/efi/EFI/refind/shutdown_flag"

# Modify refind.conf to boot Windows instantly
sed -i 's/^timeout .*/timeout -1/' "$REFIND_CONF"
sed -i 's/^default_selection .*/default_selection "Windows"/' "$REFIND_CONF"

# Create flag file on EFI partition
touch "$FLAG_FILE"

sleep 1
systemctl reboot
EOF

chmod +x /usr/local/bin/win-shutdown.sh
```

Verify:
```bash
cat /usr/local/bin/win-shutdown.sh
```

#### Step 2 — Create Systemd Service

```bash
cat > /etc/systemd/system/win-shutdown.service << 'EOF'
[Unit]
Description=Windows Shutdown via EFI Flag

[Service]
Type=oneshot
ExecStart=/usr/local/bin/win-shutdown.sh
EOF

systemctl daemon-reload
```

Verify:
```bash
cat /etc/systemd/system/win-shutdown.service
```

#### Step 3 — Configure Sudoers

Replace `onism` with your actual username (check with `whoami`):

```bash
cat > /etc/sudoers.d/win-shutdown << 'EOF'
onism ALL=(ALL) NOPASSWD: /usr/local/bin/win-shutdown.sh
onism ALL=(ALL) NOPASSWD: /bin/systemctl start win-shutdown.service
Defaults:onism !requiretty
EOF
```

Verify:
```bash
cat /etc/sudoers.d/win-shutdown
```

#### Step 4 — Bind the Key in GNOME

Exit root first, then run as your normal user:

```bash
exit

# Register custom keybinding slot
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"

# Set name
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name "Win Shutdown"

# Set command
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command "sudo systemctl start win-shutdown.service"

# Bind to KEY_PROG2 (AI button)
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding "XF86Launch2"
```

Verify:
```bash
gsettings list-recursively org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
```

Expected output:
```
org.gnome.settings-daemon.plugins.media-keys.custom-keybinding binding 'XF86Launch2'
org.gnome.settings-daemon.plugins.media-keys.custom-keybinding command 'sudo systemctl start win-shutdown.service'
org.gnome.settings-daemon.plugins.media-keys.custom-keybinding name 'Win Shutdown'
```

#### Step 5 — Final Verification

```bash
# Confirm refind.conf is clean before first real test
sudo grep -E "^timeout|^default_selection" /boot/efi/EFI/Microsoft/Boot/refind.conf
```

Expected:
```
timeout 10
default_selection "Fedora"
```

✅ Everything is ready. **Press the special key to test the full flow.**

---

## Full Flow Diagram

```
Normal Use (no key pressed):
  Power on → rEFInd (timeout 10, Fedora default) → choose OS → use normally ✅

Shutdown from Linux via special key:
  KEY_PROG2 pressed
       ↓
  win-shutdown.sh runs
       ↓
  refind.conf → timeout -1, default "Windows"
  Flag file created at /boot/efi/EFI/refind/shutdown_flag
       ↓
  System reboots
       ↓
  rEFInd reads config → instantly boots Windows (no menu)
       ↓
  Windows starts → SYSTEM task fires at boot (before login)
       ↓
  shutdown_check.bat runs:
    Mounts EFI partition as B:
    Finds shutdown_flag → deletes it
    Restores refind.conf → timeout 10, default "Fedora"
    Unmounts B:
    shutdown /s /t 5
       ↓
  Clean S5 power off ✅
  Next boot: rEFInd normal, Fedora default ✅
```

---

## Troubleshooting

### rEFInd menu disappeared after pressing key
The flag file wasn't processed — `refind.conf` is stuck with `timeout -1`. Fix from Linux:

```bash
sudo sed -i 's/^timeout .*/timeout 10/' /boot/efi/EFI/Microsoft/Boot/refind.conf
sudo sed -i 's/^default_selection .*/default_selection "Fedora"/' /boot/efi/EFI/Microsoft/Boot/refind.conf
```

### Windows auto-shuts down on normal boot
A stale flag file exists. Remove it from Linux:

```bash
sudo rm -f /boot/efi/EFI/refind/shutdown_flag
```

Also restore `refind.conf`:
```bash
sudo sed -i 's/^timeout .*/timeout 10/' /boot/efi/EFI/Microsoft/Boot/refind.conf
sudo sed -i 's/^default_selection .*/default_selection "Fedora"/' /boot/efi/EFI/Microsoft/Boot/refind.conf
```

### Can't boot Windows to fix Task Scheduler (auto-shutdown loop)
Delete the task directly from Linux:

```bash
sudo mkdir -p /mnt/windows
sudo mount /dev/nvme0n1p2 /mnt/windows
sudo rm -f "/mnt/windows/Windows/System32/Tasks/Linux Shutdown Task"
sudo umount /mnt/windows
```

### Key press does nothing
The `sudo` in the GNOME keybinding may be failing silently. Verify the systemd service runs manually:

```bash
sudo systemctl start win-shutdown.service
journalctl -u win-shutdown.service -n 20
```

### Find your Windows partition
```bash
lsblk -o NAME,FSTYPE,LABEL,SIZE
```
Look for `ntfs` partition — usually `nvme0n1p2` for system, `nvme0n1p3` for data.

---

## rEFInd Auto-Restore Service

> ⚠️ **Critical for HP OMEN:** Windows aggressively restores its own `bootmgfw.efi` every time it boots, overwriting rEFInd. Without this service, rEFInd disappears after every Windows boot.

This systemd service runs early on every Fedora boot, checks if Windows overwrote rEFInd, and automatically restores it.

### Install the Service

```bash
sudo -i

# Create the protection script
cat > /usr/local/bin/refind-protect.sh << 'EOF'
#!/bin/bash

REFIND_SOURCE="/usr/share/rEFInd/refind/refind_x64.efi"
REFIND_TARGET="/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"

# If file is larger than 1MB, Windows overwrote rEFInd
FILESIZE=$(stat -c%s "$REFIND_TARGET")
if [ "$FILESIZE" -gt 1048576 ]; then
    cp -f "$REFIND_SOURCE" "$REFIND_TARGET"
    echo "rEFInd restored at $(date)" >> /var/log/refind-protect.log
else
    echo "rEFInd OK at $(date)" >> /var/log/refind-protect.log
fi
EOF

chmod +x /usr/local/bin/refind-protect.sh

# Create the systemd service
cat > /etc/systemd/system/refind-protect.service << 'EOF'
[Unit]
Description=Restore rEFInd if Windows overwrote it
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refind-protect.sh

[Install]
WantedBy=sysinit.target
EOF

# Enable and reload
systemctl enable refind-protect.service
systemctl daemon-reload
```

### Verify

```bash
systemctl is-enabled refind-protect.service
# Should show: enabled

# After next reboot, check the log
cat /var/log/refind-protect.log
# Shows: "rEFInd restored at ..." or "rEFInd OK at ..."
```

---

## Hide GRUB Menu (Optional)

By default, selecting Fedora from rEFInd shows the GRUB menu before booting. To skip it:

```bash
sudo nano /etc/default/grub
# Change: GRUB_TIMEOUT=5
# To:     GRUB_TIMEOUT=0

sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

After reboot, rEFInd → Fedora boots directly with no GRUB menu in between.

---

## Reverting Everything

To completely remove all changes:

```bash
# Linux side
sudo rm -f /usr/local/bin/win-shutdown.sh
sudo rm -f /etc/sudoers.d/win-shutdown
sudo systemctl stop win-shutdown.service 2>/dev/null
sudo rm -f /etc/systemd/system/win-shutdown.service

# Remove rEFInd protect service
sudo systemctl disable refind-protect.service 2>/dev/null
sudo rm -f /usr/local/bin/refind-protect.sh
sudo rm -f /etc/systemd/system/refind-protect.service

sudo systemctl daemon-reload

# Remove GNOME key binding
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "[]"

# Restore refind.conf
sudo sed -i 's/^timeout .*/timeout 10/' /boot/efi/EFI/Microsoft/Boot/refind.conf
sudo sed -i 's/^default_selection .*/default_selection "Fedora"/' /boot/efi/EFI/Microsoft/Boot/refind.conf

# Remove flag file if exists
sudo rm -f /boot/efi/EFI/refind/shutdown_flag
```

On Windows side:
1. Open `taskschd.msc`
2. Find and delete **"Linux Shutdown Task"**
3. Delete `C:\shutdown_check.bat`

---

## Why efibootmgr Doesn't Work

You might think the simpler solution is `efibootmgr --bootnext` to boot Windows directly. This **does not work** on HP OMEN and many gaming laptops because:

- HP firmware **deletes unknown EFI boot entries** on every boot
- The `BootNext` EFI variable is **ignored or cleared** by HP's firmware
- This is a known issue with HP, Lenovo, and ASUS gaming series laptops
- The firmware enforces its own boot order and doesn't respect OS-level EFI variable writes reliably

The `refind.conf` + flag file approach works because it operates entirely at the **filesystem level** (FAT32 EFI partition) which the firmware cannot interfere with.

---

## Hardware Info

| Item | Detail |
|------|--------|
| Device | HP OMEN 16 |
| Boot Manager | rEFInd |
| Linux | Fedora (any distro applies) |
| Special Key | AI Button (`KEY_PROG2`, keycode 149, X11: `XF86Launch2`) |
| EFI Partition | `/dev/nvme0n1p4` mounted at `/boot/efi` |
| rEFInd Config | `/boot/efi/EFI/Microsoft/Boot/refind.conf` |
| Flag File | `/boot/efi/EFI/refind/shutdown_flag` |
| Windows Script | `C:\shutdown_check.bat` |

---

## Credits

Solution developed through debugging session identifying HP OMEN firmware-level EFI restrictions and designing a filesystem-based workaround using rEFInd config modification and EFI partition flag files.

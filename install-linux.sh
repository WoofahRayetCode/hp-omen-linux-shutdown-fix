#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

if [ "$(id -u)" -ne 0 ]; then
  die "Run this with sudo: sudo bash ./install-linux.sh"
fi

ACTION="install"
ACPI_S5=0
for arg in "$@"; do
  case "$arg" in
    --acpi-s5) ACPI_S5=1 ;;
    remove|uninstall|install) ACTION="$arg" ;;
    *) die "Unknown argument: $arg (use install, remove, and optional --acpi-s5)" ;;
  esac
done
SYSTEMCTL_PATH="$(command -v systemctl || die "systemctl command not found")"
GSETTINGS_PATH="$(command -v gsettings || true)"

CURRENT_USER="${SUDO_USER:-}"
if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
  CURRENT_USER="${LOGNAME:-}"
  if [ "$CURRENT_USER" = "root" ] || [ -z "$CURRENT_USER" ]; then
    CURRENT_USER="$(logname 2>/dev/null || true)"
  fi
fi

CURRENT_HOME=""
if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
  CURRENT_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6 || true)"
fi

KEYBINDING_NAME="OMEN Clean Shutdown"
KEYBINDING_COMMAND="/usr/local/bin/omen-clean-shutdown-launcher"
KEYBINDING_KEY="XF86Launch2"
KEYBINDING_PATH=""

source /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "fedora" ] && [[ "${ID_LIKE:-}" != *fedora* ]] && \
   [ "${ID:-}" != "cachyos" ] && [ "${ID:-}" != "arch" ] && [[ "${ID_LIKE:-}" != *arch* ]]; then
  info "This installer is written for Fedora/Nobara and Arch/CachyOS, but will keep going."
fi

EFI_MOUNT_EXPLICIT="${EFI_MOUNT:-}"
EFI_MOUNT="${EFI_MOUNT:-}"
EFI_MOUNTED_BY_SCRIPT=0

detect_efi_mount() {
  if [ -n "$EFI_MOUNT_EXPLICIT" ]; then
    EFI_MOUNT="$EFI_MOUNT_EXPLICIT"
    return 0
  fi

  local candidate
  for candidate in /boot/efi /efi /boot; do
    if findmnt -n -o TARGET "$candidate" >/dev/null 2>&1 || mountpoint -q "$candidate" 2>/dev/null; then
      if [ -d "$candidate/EFI" ] || [ -f "$candidate/refind.conf" ]; then
        EFI_MOUNT="$candidate"
        return 0
      fi
    fi
  done

  for candidate in /boot/efi /efi /boot; do
    if [ -d "$candidate/EFI" ]; then
      EFI_MOUNT="$candidate"
      return 0
    fi
  done

  EFI_MOUNT="/boot/efi"
}

ensure_efi_mounted() {
  detect_efi_mount

  if findmnt -n -o TARGET "$EFI_MOUNT" >/dev/null 2>&1 || mountpoint -q "$EFI_MOUNT" 2>/dev/null; then
    info "EFI partition already mounted at $EFI_MOUNT"
    return 0
  fi

  info "Searching for EFI System Partition..."
  local efi_part=""
  # GPT GUID for EFI System Partition
  efi_part="$(lsblk -o NAME,PARTTYPE -p -n 2>/dev/null | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')"
  if [ -z "$efi_part" ]; then
    efi_part="$(lsblk -o NAME,PARTTYPE -p -n 2>/dev/null | awk '$2 == "ef00" || $2 == "ef" || $2 == "0xef" {print $1; exit}')"
  fi

  if [ -n "$efi_part" ]; then
    local existing_target
    existing_target="$(findmnt -n -o TARGET "$efi_part" 2>/dev/null | head -n1 || true)"
    if [ -n "$existing_target" ]; then
      EFI_MOUNT="$existing_target"
      info "EFI partition $efi_part is already mounted at $EFI_MOUNT"
      return 0
    fi
  fi

  if [ -z "$efi_part" ]; then
    die "Could not find the EFI System Partition. Mount it manually at $EFI_MOUNT or set EFI_MOUNT."
  fi

  info "Mounting EFI partition $efi_part at $EFI_MOUNT..."
  mkdir -p "$EFI_MOUNT"
  if mount "$efi_part" "$EFI_MOUNT"; then
    EFI_MOUNTED_BY_SCRIPT=1
  else
    die "Failed to mount EFI partition $efi_part at $EFI_MOUNT"
  fi
}

find_refind_conf() {
  local candidate

  for candidate in \
    "${REFIND_CONF:-}" \
    "$EFI_MOUNT/EFI/refind/refind.conf" \
    "$EFI_MOUNT/EFI/Microsoft/Boot/refind.conf" \
    "$EFI_MOUNT/refind.conf" \
    "/boot/efi/EFI/refind/refind.conf" \
    "/boot/efi/EFI/Microsoft/Boot/refind.conf" \
    "/efi/EFI/refind/refind.conf" \
    "/efi/EFI/Microsoft/Boot/refind.conf" \
    "/boot/EFI/refind/refind.conf" \
    "/boot/EFI/Microsoft/Boot/refind.conf"
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ -d "$EFI_MOUNT" ]; then
    find "$EFI_MOUNT" -maxdepth 4 -name 'refind.conf' -print -quit 2>/dev/null || true
  fi
}

find_refind_source() {
  local candidate

  for candidate in \
    "${REFIND_SOURCE:-}" \
    "/usr/share/refind/refind_x64.efi" \
    "/usr/share/rEFInd/refind/refind_x64.efi" \
    "$EFI_MOUNT/EFI/refind/refind_x64.efi"
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

ensure_efi_mounted

FLAG_FILE="${FLAG_FILE:-$EFI_MOUNT/EFI/refind/shutdown_flag}"
RESTORE_FILE="${RESTORE_FILE:-$EFI_MOUNT/EFI/refind/default_selection_restore}"

REFIND_CONF_PATH="$(find_refind_conf)"
[ -n "$REFIND_CONF_PATH" ] || die "Could not find refind.conf. Mount your EFI partition at $EFI_MOUNT or set REFIND_CONF."

REFIND_SOURCE="$(find_refind_source)"
[ -n "$REFIND_SOURCE" ] || die "Could not find refind_x64.efi. Please install rEFInd (e.g. 'sudo pacman -S refind' on CachyOS/Arch or 'sudo dnf install refind' on Fedora)."

REFIND_TARGET="${REFIND_TARGET:-$EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi}"

detect_keybinding() {
  local key_line=""

  if [ -t 0 ] && command -v libinput >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    info "Press Enter, then press the Copilot/AI button once within 8 seconds."
    read -r _ || true
    key_line="$(timeout 8s sh -c 'libinput debug-events 2>&1' | grep -m1 -o 'KEY_PROG[1-4]' || true)"
    case "$key_line" in
      KEY_PROG1) KEYBINDING_KEY="XF86Launch1" ;;
      KEY_PROG2) KEYBINDING_KEY="XF86Launch2" ;;
      KEY_PROG3) KEYBINDING_KEY="XF86Launch3" ;;
      KEY_PROG4) KEYBINDING_KEY="XF86Launch4" ;;
      *) KEYBINDING_KEY="XF86Launch2" ;;
    esac
    info "Detected $key_line; using binding key $KEYBINDING_KEY."
  else
    info "Using default binding key $KEYBINDING_KEY."
  fi
}

install_files() {
  info "Installing helper scripts..."

  cat >/usr/local/bin/omen-clean-shutdown.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\$(id -u)" -ne 0 ]; then
  echo "error: Run this script with sudo or use /usr/local/bin/omen-clean-shutdown-launcher" >&2
  exit 1
fi

REFIND_CONF="$REFIND_CONF_PATH"
FLAG_FILE="$FLAG_FILE"
RESTORE_FILE="$RESTORE_FILE"
LOG_FILE="/var/log/omen-clean-shutdown.log"

log() { echo "\$(date -Is 2>/dev/null || date) \$*" >> "\$LOG_FILE" 2>/dev/null || true; }

if [ -e /etc/omen-native-poweroff ]; then
  log "native poweroff flag present; not intercepting"
  exit 0
fi

[ -f "\$REFIND_CONF" ] || { echo "Missing refind.conf: \$REFIND_CONF" >&2; log "missing refind.conf"; exit 1; }
mkdir -p "\$(dirname "\$FLAG_FILE")"
log "starting Windows-reboot shutdown workaround"

if [ ! -f "\${REFIND_CONF}.bak" ]; then
  cp -f "\$REFIND_CONF" "\${REFIND_CONF}.bak"
fi
RESTORE_TIMEOUT_FILE="\${RESTORE_FILE}_timeout"

current_selection="\$(grep '^[[:space:]]*default_selection[[:space:]]' "\$REFIND_CONF" || true)"
if [ -n "\$current_selection" ]; then
  printf '%s\n' "\$current_selection" > "\$RESTORE_FILE"
else
  printf '# default_selection not set\n' > "\$RESTORE_FILE"
fi

current_timeout="\$(grep '^[[:space:]]*timeout[[:space:]]' "\$REFIND_CONF" || true)"
if [ -n "\$current_timeout" ]; then
  printf '%s\n' "\$current_timeout" > "\$RESTORE_TIMEOUT_FILE"
else
  printf 'timeout 0\n' > "\$RESTORE_TIMEOUT_FILE"
fi

if grep -q '^[[:space:]]*timeout[[:space:]]' "\$REFIND_CONF"; then
  sed -i 's/^[[:space:]]*timeout[[:space:]].*/timeout -1/' "\$REFIND_CONF"
else
  printf '\ntimeout -1\n' >> "\$REFIND_CONF"
fi

if grep -q '^[[:space:]]*default_selection[[:space:]]' "\$REFIND_CONF"; then
  sed -i 's/^[[:space:]]*default_selection[[:space:]].*/default_selection "Windows"/' "\$REFIND_CONF"
else
  printf '\ndefault_selection "Windows"\n' >> "\$REFIND_CONF"
fi

touch "\$FLAG_FILE"
sync
log "flag written; rebooting into Windows"
systemctl start reboot.target --job-mode=replace-irreversibly
EOF

  cat >/usr/local/bin/omen-clean-shutdown-launcher <<EOF
#!/usr/bin/env bash
set -euo pipefail

confirm_shutdown() {
  if command -v kdialog >/dev/null 2>&1; then
    kdialog --title "Confirm Shutdown" --yesno "Shut down the laptop using the Windows workaround?"
    return \$?
  elif command -v zenity >/dev/null 2>&1; then
    zenity --question --title="Confirm Shutdown" --text="Shut down the laptop using the Windows workaround?"
    return \$?
  elif command -v yad >/dev/null 2>&1; then
    yad --image=dialog-question --title="Confirm Shutdown" --text="Shut down the laptop using the Windows workaround?" --button=Yes:0 --button=No:1
    return \$?
  fi
  echo "No dialog tool found (kdialog, zenity, or yad); proceeding without confirmation." >&2
  return 0
}

if ! confirm_shutdown; then
  exit 0
fi

exec sudo "$SYSTEMCTL_PATH" start omen-clean-shutdown.service
EOF

  cat >/usr/local/bin/refind-protect.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

REFIND_SOURCE="$REFIND_SOURCE"
REFIND_TARGET="$REFIND_TARGET"

if [ ! -f "\$REFIND_SOURCE" ]; then
  echo "Missing rEFInd source: \$REFIND_SOURCE" >&2
  exit 1
fi

if [ ! -f "\$REFIND_TARGET" ]; then
  echo "Target \$REFIND_TARGET does not exist, skipping rEFInd protection." >&2
  exit 0
fi

FILESIZE=\$(stat -c%s "\$REFIND_TARGET" 2>/dev/null || stat -f%z "\$REFIND_TARGET" 2>/dev/null || echo 0)
if [ "\$FILESIZE" -gt 1048576 ]; then
  cp -f "\$REFIND_SOURCE" "\$REFIND_TARGET"
fi
EOF

  chmod 0755 /usr/local/bin/omen-clean-shutdown.sh
  chmod 0755 /usr/local/bin/omen-clean-shutdown-launcher
  chmod 0755 /usr/local/bin/refind-protect.sh

  cat >/usr/share/applications/omen-clean-shutdown.desktop <<EOF
[Desktop Entry]
Type=Application
Name=OMEN Clean Shutdown
Comment=Shut down HP OMEN laptop cleanly via Windows workaround
Exec=/usr/local/bin/omen-clean-shutdown-launcher
Icon=system-shutdown
Categories=System;Utility;
Terminal=false
X-KDE-Shortcuts=$KEYBINDING_KEY
EOF
  chmod 0644 /usr/share/applications/omen-clean-shutdown.desktop

  cat >/etc/systemd/system/omen-clean-shutdown.service <<'EOF'
[Unit]
Description=OMEN clean shutdown via Windows
DefaultDependencies=no
Conflicts=reboot.target
Before=poweroff.target halt.target
ConditionPathExists=!/etc/omen-native-poweroff

[Service]
Type=oneshot
ExecStart=/usr/local/bin/omen-clean-shutdown.sh
RemainAfterExit=yes

[Install]
WantedBy=poweroff.target halt.target
EOF

  mkdir -p /etc/systemd/system/poweroff.target.d
  cat >/etc/systemd/system/poweroff.target.d/omen-clean-shutdown.conf <<'EOF'
[Unit]
Wants=omen-clean-shutdown.service
After=omen-clean-shutdown.service
EOF

  cat >/etc/systemd/system/refind-protect.service <<'EOF'
[Unit]
Description=Restore rEFInd if Windows overwrites the boot manager
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/refind-protect.sh

[Install]
WantedBy=sysinit.target
EOF

  if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    info "Creating sudoers rule for $CURRENT_USER..."
    cat >/etc/sudoers.d/omen-clean-shutdown <<EOF
$CURRENT_USER ALL=(root) NOPASSWD: $SYSTEMCTL_PATH start omen-clean-shutdown.service
Defaults:$CURRENT_USER !requiretty
EOF
    chmod 0440 /etc/sudoers.d/omen-clean-shutdown
    if command -v visudo >/dev/null 2>&1; then
      visudo -cf /etc/sudoers.d/omen-clean-shutdown >/dev/null
    fi
  fi

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$SCRIPT_DIR/linux/omen-shutdown-diagnose.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/linux/omen-shutdown-diagnose.sh" /usr/local/bin/omen-shutdown-diagnose
  fi
  mkdir -p /usr/local/share/omen-clean-shutdown
  if [ -f "$SCRIPT_DIR/acpi/ssdt-omen-s5.asl" ]; then
    install -m 0644 "$SCRIPT_DIR/acpi/ssdt-omen-s5.asl" /usr/local/share/omen-clean-shutdown/ssdt-omen-s5.asl
  fi

  systemctl daemon-reload
  systemctl enable refind-protect.service >/dev/null
  systemctl enable omen-clean-shutdown.service >/dev/null

  if [ "$ACPI_S5" -eq 1 ]; then
    info "Experimental ACPI S5 template installed to /usr/local/share/omen-clean-shutdown/ssdt-omen-s5.asl"
    info "This does NOT load AML automatically. Dump your DSDT, confirm PG00/GPTS paths, compile with iasl,"
    info "and add a second bootloader entry. Keep the Windows-reboot workaround until S5 is proven (LED off, chassis cold)."
    info "See README and https://github.com/paolo-de-marinis/omen-acpi/releases/tag/v2.2.0"
  fi

  detect_keybinding

  if [ -n "$GSETTINGS_PATH" ] && [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    info "Trying to bind key in GNOME (without replacing existing custom shortcuts)..."
    existing_raw="$(sudo -u "$CURRENT_USER" dbus-run-session -- gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo '@as []')"
    n=0
    while printf '%s' "$existing_raw" | grep -q "custom${n}/"; do
      n=$((n + 1))
      if [ "$n" -gt 32 ]; then
        break
      fi
    done
    KEYBINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${n}/"
    if printf '%s' "$existing_raw" | grep -q '@as \[\]' || [ "$existing_raw" = "[]" ]; then
      listed="['$KEYBINDING_PATH']"
    else
      listed="$(printf '%s' "$existing_raw" | sed "s|]$|, '$KEYBINDING_PATH']|")"
    fi
    if sudo -u "$CURRENT_USER" dbus-run-session -- sh -c "
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \"$listed\" &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH name '$KEYBINDING_NAME' &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH command '$KEYBINDING_COMMAND' &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH binding '$KEYBINDING_KEY'
    " >/dev/null 2>&1; then
      info "GNOME keybinding created at $KEYBINDING_PATH for $KEYBINDING_KEY."
    fi
  fi

  if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ] && [ -n "$CURRENT_HOME" ]; then
    if command -v kwriteconfig6 >/dev/null 2>&1; then
      info "Configuring KDE Plasma 6 shortcut for $CURRENT_USER..."
      sudo -u "$CURRENT_USER" kwriteconfig6 --file "$CURRENT_HOME/.config/kglobalshortcutsrc" --group "services" --key "omen-clean-shutdown.desktop" "_launch=$KEYBINDING_KEY,none,OMEN Clean Shutdown" || true
    elif command -v kwriteconfig5 >/dev/null 2>&1; then
      info "Configuring KDE Plasma 5 shortcut for $CURRENT_USER..."
      sudo -u "$CURRENT_USER" kwriteconfig5 --file "$CURRENT_HOME/.config/kglobalshortcutsrc" --group "services" --key "omen-clean-shutdown.desktop" "_launch=$KEYBINDING_KEY,none,OMEN Clean Shutdown" || true
    fi
  fi

  info "Installed successfully."
  echo
  echo "You can launch OMEN Clean Shutdown using:"
  echo "  1. App launcher menu: search for 'OMEN Clean Shutdown'"
  echo "  2. Launcher command: omen-clean-shutdown-launcher"
  echo "  3. Keybinding ($KEYBINDING_KEY)"
  echo "  4. Desktop/session Shut Down and systemctl poweroff (intercepted)"
  echo
  echo "Escape hatch (real firmware poweroff, may leave dGPU rail on):"
  echo "  sudo touch /etc/omen-native-poweroff"
  echo "Logs: /var/log/omen-clean-shutdown.log"
  echo "Diagnose: sudo omen-shutdown-diagnose"
  echo
}

remove_files() {
  info "Removing helper files..."
  ensure_efi_mounted
  systemctl stop omen-clean-shutdown.service 2>/dev/null || true
  systemctl disable omen-clean-shutdown.service 2>/dev/null || true
  systemctl disable refind-protect.service 2>/dev/null || true
  rm -f /usr/local/bin/omen-clean-shutdown.sh
  rm -f /usr/local/bin/omen-clean-shutdown-launcher
  rm -f /usr/local/bin/refind-protect.sh
  rm -f /usr/local/bin/omen-shutdown-diagnose
  rm -f /usr/share/applications/omen-clean-shutdown.desktop
  rm -f /etc/systemd/system/omen-clean-shutdown.service
  rm -f /etc/systemd/system/refind-protect.service
  rm -f /etc/systemd/system/poweroff.target.d/omen-clean-shutdown.conf
  rmdir /etc/systemd/system/poweroff.target.d 2>/dev/null || true
  rm -f /etc/sudoers.d/omen-clean-shutdown
  rm -rf /usr/local/share/omen-clean-shutdown
  if [ -n "${REFIND_CONF_PATH:-}" ] && [ -f "${REFIND_CONF_PATH}.bak" ]; then
    cp -f "${REFIND_CONF_PATH}.bak" "$REFIND_CONF_PATH"
  fi
  rm -f "$FLAG_FILE"
  rm -f "$RESTORE_FILE"
  systemctl daemon-reload
  info "Removed successfully."
}

case "$ACTION" in
  install)
    install_files
    ;;
  remove|uninstall)
    remove_files
    ;;
  *)
    die "Unknown action: $ACTION (use install or remove)"
    ;;
esac

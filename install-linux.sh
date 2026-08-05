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

ACTION="${1:-install}"
SYSTEMCTL_PATH="$(command -v systemctl)"
GSETTINGS_PATH="$(command -v gsettings || true)"
CURRENT_USER="${SUDO_USER:-}"
CURRENT_HOME=""
KEYBINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
KEYBINDING_NAME="OMEN Clean Shutdown"
KEYBINDING_COMMAND="/usr/local/bin/omen-clean-shutdown-launcher"
KEYBINDING_KEY="XF86Launch2"

if [ -n "$CURRENT_USER" ]; then
  CURRENT_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6 || true)"
fi

source /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "fedora" ] && [[ "${ID_LIKE:-}" != *fedora* ]] && [ "${ID:-}" != "cachyos" ] && [[ "${ID_LIKE:-}" != *arch* ]]; then
  info "This installer is written for Fedora/Nobara and Arch/CachyOS, but will keep going."
fi

EFI_MOUNT="${EFI_MOUNT:-/boot/efi}"
REFIND_CONF="${REFIND_CONF:-}"
FLAG_FILE="${FLAG_FILE:-$EFI_MOUNT/EFI/refind/shutdown_flag}"
RESTORE_FILE="${RESTORE_FILE:-$EFI_MOUNT/EFI/refind/default_selection_restore}"

if [ -z "${REFIND_SOURCE:-}" ]; then
  if [ -f "/usr/share/refind/refind_x64.efi" ]; then
    REFIND_SOURCE="/usr/share/refind/refind_x64.efi"
  else
    REFIND_SOURCE="/usr/share/rEFInd/refind/refind_x64.efi"
  fi
fi
REFIND_TARGET="${REFIND_TARGET:-$EFI_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi}"

EFI_MOUNTED_BY_SCRIPT=0

ensure_efi_mounted() {
  if findmnt -n -o TARGET "$EFI_MOUNT" >/dev/null 2>&1 || mountpoint -q "$EFI_MOUNT" 2>/dev/null; then
    info "EFI partition already mounted at $EFI_MOUNT"
    return 0
  fi

  info "EFI partition not mounted; searching for it..."
  local efi_part=""

  # GPT GUID for EFI System Partition
  efi_part="$(lsblk -o NAME,PARTTYPE -p -n 2>/dev/null | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')"

  # MBR/GPT fallback type IDs
  if [ -z "$efi_part" ]; then
    efi_part="$(lsblk -o NAME,PARTTYPE -p -n 2>/dev/null | awk '$2 == "ef00" || $2 == "ef" || $2 == "0xef" {print $1; exit}')"
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
    "$REFIND_CONF" \
    "$EFI_MOUNT/EFI/Microsoft/Boot/refind.conf" \
    "$EFI_MOUNT/EFI/refind/refind.conf"
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ -d "$EFI_MOUNT" ]; then
    find "$EFI_MOUNT" -path '*/refind.conf' -print -quit 2>/dev/null || true
  fi
}

ensure_efi_mounted
REFIND_CONF_PATH="$(find_refind_conf)"
[ -n "$REFIND_CONF_PATH" ] || die "Could not find refind.conf. Mount your EFI partition at $EFI_MOUNT or set REFIND_CONF."

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
    info "Detected $key_line; using GNOME binding $KEYBINDING_KEY."
  else
    info "Using default GNOME binding $KEYBINDING_KEY."
  fi
}

install_files() {
  info "Installing helper scripts..."

  cat >/usr/local/bin/omen-clean-shutdown.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

REFIND_CONF="$REFIND_CONF_PATH"
FLAG_FILE="$FLAG_FILE"

[ -f "\$REFIND_CONF" ] || { echo "Missing refind.conf: \$REFIND_CONF" >&2; exit 1; }
mkdir -p "\$(dirname "\$FLAG_FILE")"

if [ ! -f "\${REFIND_CONF}.bak" ]; then
  cp -f "\$REFIND_CONF" "\${REFIND_CONF}.bak"
fi

current_selection="\$(grep '^default_selection ' "\$REFIND_CONF" || true)"
if [ -n "\$current_selection" ]; then
  printf '%s\n' "\$current_selection" > "$RESTORE_FILE"
else
  printf '# default_selection not set\n' > "$RESTORE_FILE"
fi

sed -i 's/^timeout .*/timeout -1/' "\$REFIND_CONF"
sed -i 's/^default_selection .*/default_selection "Windows"/' "\$REFIND_CONF"
touch "\$FLAG_FILE"
sync
systemctl reboot
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
  fi
  echo "No dialog tool found (kdialog or zenity); proceeding without confirmation." >&2
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

[ -f "\$REFIND_SOURCE" ] || { echo "Missing rEFInd source: \$REFIND_SOURCE" >&2; exit 1; }
[ -f "\$REFIND_TARGET" ] || { echo "Missing Windows boot file: \$REFIND_TARGET" >&2; exit 1; }

FILESIZE=\$(stat -c%s "\$REFIND_TARGET")
if [ "\$FILESIZE" -gt 1048576 ]; then
  cp -f "\$REFIND_SOURCE" "\$REFIND_TARGET"
fi
EOF

  chmod 0755 /usr/local/bin/omen-clean-shutdown.sh
  chmod 0755 /usr/local/bin/omen-clean-shutdown-launcher
  chmod 0755 /usr/local/bin/refind-protect.sh

  cat >/etc/systemd/system/omen-clean-shutdown.service <<'EOF'
[Unit]
Description=OMEN clean shutdown via Windows

[Service]
Type=oneshot
ExecStart=/usr/local/bin/omen-clean-shutdown.sh
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

  systemctl daemon-reload
  systemctl enable refind-protect.service >/dev/null

  detect_keybinding

  if [ -n "$GSETTINGS_PATH" ] && [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    info "Trying to bind the OMEN key in GNOME..."
    if sudo -u "$CURRENT_USER" dbus-run-session -- sh -c "
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \"['$KEYBINDING_PATH']\" &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH name '$KEYBINDING_NAME' &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH command '$KEYBINDING_COMMAND' &&
      gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KEYBINDING_PATH binding '$KEYBINDING_KEY'
    " >/dev/null 2>&1; then
      info "GNOME keybinding created for $KEYBINDING_KEY."
    else
      info "GNOME keybinding was not created automatically."
      info "Bind $KEYBINDING_KEY to $KEYBINDING_COMMAND manually if needed."
    fi
  fi

  info "Installed."
  echo
  echo "Use this command from a shortcut or terminal:"
  echo "  /usr/local/bin/omen-clean-shutdown-launcher"
  echo
  echo "The OMEN AI/Copilot key usually shows up on Linux as XF86Launch2."
}

remove_files() {
  info "Removing helper files..."
  ensure_efi_mounted
  systemctl stop omen-clean-shutdown.service 2>/dev/null || true
  systemctl disable refind-protect.service 2>/dev/null || true
  rm -f /usr/local/bin/omen-clean-shutdown.sh
  rm -f /usr/local/bin/omen-clean-shutdown-launcher
  rm -f /usr/local/bin/refind-protect.sh
  rm -f /etc/systemd/system/omen-clean-shutdown.service
  rm -f /etc/systemd/system/refind-protect.service
  rm -f /etc/sudoers.d/omen-clean-shutdown
  if [ -f "${REFIND_CONF_PATH}.bak" ]; then
    cp -f "${REFIND_CONF_PATH}.bak" "$REFIND_CONF_PATH"
  fi
  rm -f "$FLAG_FILE"
  rm -f "$RESTORE_FILE"
  systemctl daemon-reload
  info "Removed."
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

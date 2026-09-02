#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: Run this script with sudo or use /usr/local/bin/omen-clean-shutdown-launcher" >&2
  exit 1
fi

LIB="${OMEN_BOOT_LIB:-/usr/local/lib/omen-clean-shutdown/omen-boot-lib.sh}"
# shellcheck source=omen-boot-lib.sh
. "$LIB"

if [ -f "$OMEN_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$OMEN_ENV_FILE"
fi

LOG_FILE="${LOG_FILE:-/var/log/omen-clean-shutdown.log}"

log() { echo "$(date -Is 2>/dev/null || date) $*" >> "$LOG_FILE" 2>/dev/null || true; }

if [ -e /etc/omen-native-poweroff ]; then
  log "native poweroff flag present; not intercepting"
  exit 0
fi

EFI_MOUNT="$(detect_linux_efi_mount)"
BOOTLOADER="${BOOTLOADER:-$(detect_bootloader "$EFI_MOUNT")}"
WINDOWS_ESP_DEV="${WINDOWS_ESP_DEV:-$(detect_windows_esp_dev || true)}"
WINDOWS_BOOTNUM="${WINDOWS_BOOTNUM:-$(detect_windows_bootnum || true)}"
ONESHOT_METHOD="${ONESHOT_METHOD:-$(choose_oneshot_method "$BOOTLOADER" "$WINDOWS_BOOTNUM")}"
REFIND_CONF="${REFIND_CONF:-$(find_refind_conf_in "$EFI_MOUNT" || true)}"
RESTORE_FILE="${RESTORE_FILE:-}"

log "starting shutdown workaround bootloader=$BOOTLOADER method=$ONESHOT_METHOD esp=${WINDOWS_ESP_DEV:-none} bootnum=${WINDOWS_BOOTNUM:-none}"

esp_root="$(ensure_windows_esp_mounted_rw "${WINDOWS_ESP_DEV:-}" || true)"
if [ -z "$esp_root" ] && [ -n "${EFI_MOUNT:-}" ]; then
  esp_root="$EFI_MOUNT"
fi
if [ -z "$esp_root" ]; then
  echo "Could not mount a Windows EFI System Partition to write the shutdown flag." >&2
  log "failed to mount Windows ESP"
  exit 1
fi

flag_file="${FLAG_FILE:-$esp_root/$OMEN_FLAG_RELPATH}"
mkdir -p "$(dirname "$flag_file")"
touch "$flag_file"

if [ -n "$REFIND_CONF" ] && [ -f "$REFIND_CONF" ]; then
  legacy_dir="$(dirname "$REFIND_CONF")"
  legacy_flag="${legacy_dir}/shutdown_flag"
  restore_file="${RESTORE_FILE:-$legacy_dir/default_selection_restore}"
  restore_timeout="${restore_file}_timeout"
  mkdir -p "$legacy_dir"
  if [ ! -f "${REFIND_CONF}.bak" ]; then
    cp -f "$REFIND_CONF" "${REFIND_CONF}.bak"
  fi
  current_selection="$(grep '^[[:space:]]*default_selection[[:space:]]' "$REFIND_CONF" || true)"
  if [ -n "$current_selection" ]; then
    printf '%s\n' "$current_selection" > "$restore_file"
  else
    printf '# default_selection not set\n' > "$restore_file"
  fi
  current_timeout="$(grep '^[[:space:]]*timeout[[:space:]]' "$REFIND_CONF" || true)"
  if [ -n "$current_timeout" ]; then
    printf '%s\n' "$current_timeout" > "$restore_timeout"
  else
    printf 'timeout 0\n' > "$restore_timeout"
  fi
  if grep -q '^[[:space:]]*timeout[[:space:]]' "$REFIND_CONF"; then
    sed -i 's/^[[:space:]]*timeout[[:space:]].*/timeout -1/' "$REFIND_CONF"
  else
    printf '\ntimeout -1\n' >> "$REFIND_CONF"
  fi
  if grep -q '^[[:space:]]*default_selection[[:space:]]' "$REFIND_CONF"; then
    sed -i 's/^[[:space:]]*default_selection[[:space:]].*/default_selection "Windows"/' "$REFIND_CONF"
  else
    printf '\ndefault_selection "Windows"\n' >> "$REFIND_CONF"
  fi
  touch "$legacy_flag"
fi

sync

set_bootnext() {
  local num="${1:-}"
  [ -n "$num" ] || return 1
  command -v efibootmgr >/dev/null 2>&1 || return 1
  efibootmgr --bootnext "$num" >/dev/null
}

set_loader_oneshot() {
  local entry="${LIMINE_WINDOWS_ENTRY:-${SYSTEMD_WINDOWS_ENTRY:-}}"
  if [ -z "$entry" ]; then
    entry="$(limine_windows_entry "$EFI_MOUNT" || true)"
  fi
  if command -v bootctl >/dev/null 2>&1; then
    if [ -n "$entry" ]; then
      bootctl set-oneshot "$entry" && return 0
    fi
    bootctl set-oneshot windows 2>/dev/null && return 0
    bootctl set-oneshot auto-windows 2>/dev/null && return 0
  fi
  return 1
}

set_grub_reboot() {
  grubenv_is_writable_at_boot || return 1
  local entry="${GRUB_WINDOWS_ENTRY:-$(grub_windows_entry || true)}"
  local cmd=""
  if command -v grub-reboot >/dev/null 2>&1; then
    cmd=grub-reboot
  elif command -v grub2-reboot >/dev/null 2>&1; then
    cmd=grub2-reboot
  else
    return 1
  fi
  if [ -z "$entry" ]; then
    local cfg
    cfg="$(find_grub_cfg || true)"
    [ -n "$cfg" ] || return 1
    entry="$(awk -F"'" '/^[[:space:]]*menuentry / && tolower($2) ~ /windows/ { print $2; exit }' "$cfg")"
  fi
  [ -n "$entry" ] || return 1
  "$cmd" "$entry"
}

oneshot_ok=0
case "$ONESHOT_METHOD" in
  refind-conf)
    if [ -n "$REFIND_CONF" ] && [ -f "$REFIND_CONF" ]; then
      oneshot_ok=1
    fi
    # If rEFInd did not replace Windows Boot Manager, BootNext still helps.
    set_bootnext "$WINDOWS_BOOTNUM" && oneshot_ok=1 || true
    ;;
  loader-oneshot)
    set_bootnext "$WINDOWS_BOOTNUM" && oneshot_ok=1 || true
    if [ "$oneshot_ok" -eq 0 ]; then
      set_loader_oneshot && oneshot_ok=1 || true
    fi
    ;;
  grub-reboot)
    set_bootnext "$WINDOWS_BOOTNUM" && oneshot_ok=1 || true
    if [ "$oneshot_ok" -eq 0 ]; then
      set_grub_reboot && oneshot_ok=1 || true
    fi
    ;;
  bootnext|*)
    set_bootnext "$WINDOWS_BOOTNUM" && oneshot_ok=1 || true
    if [ "$oneshot_ok" -eq 0 ]; then
      set_loader_oneshot && oneshot_ok=1 || true
    fi
    if [ "$oneshot_ok" -eq 0 ]; then
      set_grub_reboot && oneshot_ok=1 || true
    fi
    ;;
esac

if [ "$oneshot_ok" -eq 0 ]; then
  echo "Could not set a one-shot Windows boot (BootNext / bootctl / grub-reboot)." >&2
  log "failed to set one-shot Windows boot"
  exit 1
fi

log "flag written at $flag_file; rebooting into Windows"
systemctl start reboot.target --job-mode=replace-irreversibly

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

# Env file values can go stale after Windows/firmware updates. Re-probe NVRAM
# and the Windows ESP, and only fall back to the saved values.
_fallback_esp="${WINDOWS_ESP_DEV:-}"
_fallback_bootnum="${WINDOWS_BOOTNUM:-}"
_forced_method="${ONESHOT_METHOD:-}"
WINDOWS_ESP_DEV=""
WINDOWS_BOOTNUM=""

EFI_MOUNT="$(detect_linux_efi_mount)"
BOOTLOADER="${BOOTLOADER:-$(detect_bootloader "$EFI_MOUNT")}"
WINDOWS_ESP_DEV="$(detect_windows_esp_dev || true)"
WINDOWS_ESP_DEV="${WINDOWS_ESP_DEV:-$_fallback_esp}"
WINDOWS_BOOTNUM="$(detect_windows_bootnum || true)"
WINDOWS_BOOTNUM="${WINDOWS_BOOTNUM:-$_fallback_bootnum}"
if [ -n "$_forced_method" ]; then
  ONESHOT_METHOD="$_forced_method"
else
  ONESHOT_METHOD="$(choose_oneshot_method "$BOOTLOADER" "$WINDOWS_BOOTNUM")"
fi
REFIND_CONF="${REFIND_CONF:-$(find_refind_conf_in "$EFI_MOUNT" || true)}"
RESTORE_FILE="${RESTORE_FILE:-}"

log "starting shutdown workaround bootloader=$BOOTLOADER method=$ONESHOT_METHOD esp=${WINDOWS_ESP_DEV:-none} bootnum=${WINDOWS_BOOTNUM:-none}"

esp_root="$(ensure_windows_esp_mounted_rw "${WINDOWS_ESP_DEV:-}" || true)"
# Never write the flag to the Linux ESP unless it actually holds bootmgfw.efi.
# Dual-drive OMEN setups have two ESPs; Windows will not see a flag on Disk 1.
if [ -z "$esp_root" ] && [ -n "${EFI_MOUNT:-}" ] && has_windows_bootmgr "$EFI_MOUNT"; then
  esp_root="$EFI_MOUNT"
fi
if [ -z "$esp_root" ]; then
  echo "Could not mount a Windows EFI System Partition to write the shutdown flag." >&2
  log "failed to mount Windows ESP"
  exit 1
fi
if ! has_windows_bootmgr "$esp_root"; then
  echo "Mounted $esp_root but it has no Windows Boot Manager (bootmgfw.efi)." >&2
  log "refusing to write shutdown_flag on non-Windows ESP at $esp_root"
  exit 1
fi

flag_file="$esp_root/$OMEN_FLAG_RELPATH"
# Honor FLAG_FILE only when it lives on the Windows ESP we just mounted.
if [ -n "${FLAG_FILE:-}" ]; then
  case "$FLAG_FILE" in
    "$esp_root"/*) flag_file="$FLAG_FILE" ;;
  esac
fi
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

efibootmgr_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 efibootmgr "$@"
  else
    efibootmgr "$@"
  fi
}

normalize_bootnum() {
  local num="${1:-}"
  num="${num#Boot}"
  num="${num%%[^0-9A-Fa-f]*}"
  printf '%s' "$num"
}

set_bootnext() {
  local num
  num="$(normalize_bootnum "${1:-}")"
  [ -n "$num" ] || return 1
  command -v efibootmgr >/dev/null 2>&1 || return 1
  efibootmgr_cmd --bootnext "$num" >/dev/null
}

bootnext_is_set() {
  command -v efibootmgr >/dev/null 2>&1 || return 1
  efibootmgr_cmd 2>/dev/null | grep -qiE '^BootNext:'
}

prefer_efi_reboot() {
  # HP firmware often ignores BootNext across an ACPI reset. EFI ResetSystem
  # is what actually consumes BootNext and boots Windows Boot Manager.
  if [ -w /sys/kernel/reboot/mode ]; then
    echo efi >/sys/kernel/reboot/mode 2>/dev/null || true
    log "reboot mode=$(cat /sys/kernel/reboot/mode 2>/dev/null || echo unknown)"
  fi
}

unmount_temp_windows_esp() {
  if [ -n "${OMEN_ESP_MOUNTPOINT:-}" ] && findmnt -n "$OMEN_ESP_MOUNTPOINT" >/dev/null 2>&1; then
    umount "$OMEN_ESP_MOUNTPOINT" 2>/dev/null || umount -l "$OMEN_ESP_MOUNTPOINT" 2>/dev/null || true
  fi
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
  log "failed to set one-shot Windows boot; efibootmgr: $(efibootmgr_cmd 2>/dev/null | tr '\n' ' ' || echo none)"
  rm -f "$flag_file"
  exit 1
fi

if [ -n "$WINDOWS_BOOTNUM" ]; then
  if bootnext_is_set; then
    log "BootNext confirmed for Boot$(normalize_bootnum "$WINDOWS_BOOTNUM")"
  else
    log "warning: efibootmgr --bootnext did not stick; firmware may ignore BootNext"
  fi
fi

if [ ! -f "$flag_file" ]; then
  echo "shutdown_flag was not written to $flag_file" >&2
  log "flag missing after write at $flag_file"
  exit 1
fi

prefer_efi_reboot
unmount_temp_windows_esp
sync

log "flag written at $flag_file; rebooting into Windows"
# --no-block is required: this unit used to Conflicts=reboot.target, which
# deadlocked (reboot waited to stop us, we waited for reboot). Even without
# Conflicts, blocking here can stall the poweroff→reboot conversion.
systemctl start reboot.target --job-mode=replace-irreversibly --no-block
exit 0

#!/usr/bin/env bash
# Shared detection helpers for install-linux.sh and omen-clean-shutdown.sh.
# shellcheck shell=bash

ESP_PARTTYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
OMEN_FLAG_RELPATH="EFI/omen/shutdown_flag"
OMEN_ESP_MOUNTPOINT="${OMEN_ESP_MOUNTPOINT:-/run/omen-windows-esp}"
OMEN_ENV_FILE="${OMEN_ENV_FILE:-/etc/omen-clean-shutdown.env}"

list_esp_devs() {
  lsblk -o NAME,PARTTYPE -p -n 2>/dev/null | awk -v g="$ESP_PARTTYPE_GUID" '
    BEGIN { gl = tolower(g) }
    {
      t = tolower($2)
      if (t == gl || t == "ef00" || t == "ef" || t == "0xef") print $1
    }
  '
}

mounted_target() {
  findmnt -n -o TARGET --source "$1" 2>/dev/null | head -n1 || true
}

fstype_of_path() {
  findmnt -n -o FSTYPE --target "$1" 2>/dev/null | head -n1 || true
}

has_windows_bootmgr() {
  local root="$1"
  [ -f "$root/EFI/Microsoft/Boot/bootmgfw.efi" ] || [ -f "$root/efi/Microsoft/Boot/bootmgfw.efi" ]
}

has_efi_dir() {
  local root="$1"
  [ -d "$root/EFI" ] || [ -d "$root/efi" ]
}

with_esp_root() {
  # with_esp_root <device> <callback>
  # Mounts the device read-only if needed, runs callback with the root path, unmounts if we mounted.
  local dev="$1"
  local cb="$2"
  local existing tmp mounted=0 rc=0

  existing="$(mounted_target "$dev")"
  if [ -n "$existing" ]; then
    "$cb" "$existing"
    return $?
  fi

  tmp="$(mktemp -d /tmp/omen-esp.XXXXXX)"
  if mount -o ro "$dev" "$tmp" 2>/dev/null; then
    mounted=1
    "$cb" "$tmp" || rc=$?
    umount "$tmp" 2>/dev/null || true
  else
    rc=1
  fi
  rmdir "$tmp" 2>/dev/null || true
  return "$rc"
}

_probe_windows() {
  if has_windows_bootmgr "$1"; then
    printf '%s\n' "$1"
    return 0
  fi
  return 1
}

detect_windows_esp_dev() {
  if [ -n "${WINDOWS_ESP_DEV:-}" ] && [ -b "$WINDOWS_ESP_DEV" ]; then
    printf '%s\n' "$WINDOWS_ESP_DEV"
    return 0
  fi

  local dev existing tmp
  for dev in $(list_esp_devs); do
    existing="$(mounted_target "$dev")"
    if [ -n "$existing" ] && has_windows_bootmgr "$existing"; then
      printf '%s\n' "$dev"
      return 0
    fi
  done

  for dev in $(list_esp_devs); do
    tmp="$(mktemp -d /tmp/omen-esp.XXXXXX)"
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      if has_windows_bootmgr "$tmp"; then
        umount "$tmp" 2>/dev/null || true
        rmdir "$tmp" 2>/dev/null || true
        printf '%s\n' "$dev"
        return 0
      fi
      umount "$tmp" 2>/dev/null || true
    fi
    rmdir "$tmp" 2>/dev/null || true
  done
  return 1
}

detect_linux_efi_mount() {
  if [ -n "${EFI_MOUNT:-}" ]; then
    printf '%s\n' "$EFI_MOUNT"
    return 0
  fi

  local candidate
  for candidate in /boot/efi /efi /boot; do
    if findmnt -n -o TARGET "$candidate" >/dev/null 2>&1 || mountpoint -q "$candidate" 2>/dev/null; then
      if has_efi_dir "$candidate" || [ -f "$candidate/refind.conf" ] || [ -f "$candidate/limine.conf" ] || [ -f "$candidate/limine.cfg" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done

  for candidate in /boot/efi /efi /boot; do
    if has_efi_dir "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "/boot/efi"
}

find_limine_conf() {
  local candidate efi_mount="${1:-}"
  for candidate in \
    "${LIMINE_CONF:-}" \
    /boot/limine.conf \
    /boot/limine.cfg \
    /boot/limine/limine.conf \
    /boot/limine/limine.cfg \
    ${efi_mount:+"$efi_mount/limine.conf"} \
    ${efi_mount:+"$efi_mount/limine.cfg"} \
    ${efi_mount:+"$efi_mount/EFI/limine/limine.conf"} \
    ${efi_mount:+"$efi_mount/EFI/BOOT/limine.conf"}
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_grub_cfg() {
  local candidate
  for candidate in \
    "${GRUB_CFG:-}" \
    /boot/grub/grub.cfg \
    /boot/grub2/grub.cfg \
    /boot/efi/EFI/fedora/grub.cfg \
    /boot/efi/EFI/ubuntu/grub.cfg \
    /boot/efi/EFI/debian/grub.cfg
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_refind_conf_in() {
  local efi_mount="${1:-}"
  local candidate found
  for candidate in \
    "${REFIND_CONF:-}" \
    ${efi_mount:+"$efi_mount/EFI/refind/refind.conf"} \
    ${efi_mount:+"$efi_mount/EFI/Microsoft/Boot/refind.conf"} \
    ${efi_mount:+"$efi_mount/refind.conf"} \
    /boot/efi/EFI/refind/refind.conf \
    /boot/efi/EFI/Microsoft/Boot/refind.conf \
    /efi/EFI/refind/refind.conf \
    /efi/EFI/Microsoft/Boot/refind.conf \
    /boot/EFI/refind/refind.conf \
    /boot/EFI/Microsoft/Boot/refind.conf
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ -n "$efi_mount" ] && [ -d "$efi_mount" ]; then
    found="$(find "$efi_mount" -maxdepth 4 -name 'refind.conf' -print -quit 2>/dev/null || true)"
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
  fi
  return 1
}

find_refind_source_in() {
  local efi_mount="${1:-}"
  local candidate
  for candidate in \
    "${REFIND_SOURCE:-}" \
    /usr/share/refind/refind_x64.efi \
    /usr/share/rEFInd/refind/refind_x64.efi \
    ${efi_mount:+"$efi_mount/EFI/refind/refind_x64.efi"}
  do
    if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

detect_bootloader() {
  local efi_mount="${1:-}"
  local forced="${BOOTLOADER:-}"
  if [ -n "$forced" ]; then
    printf '%s\n' "$forced"
    return 0
  fi

  if find_limine_conf "$efi_mount" >/dev/null; then
    printf '%s\n' "limine"
    return 0
  fi
  if find_refind_conf_in "$efi_mount" >/dev/null; then
    printf '%s\n' "refind"
    return 0
  fi
  if [ -f /boot/loader/loader.conf ] || [ -d /boot/loader/entries ]; then
    printf '%s\n' "systemd-boot"
    return 0
  fi
  if find_grub_cfg >/dev/null; then
    printf '%s\n' "grub"
    return 0
  fi
  printf '%s\n' "unknown"
}

detect_windows_bootnum() {
  if [ -n "${WINDOWS_BOOTNUM:-}" ]; then
    printf '%s\n' "$WINDOWS_BOOTNUM"
    return 0
  fi
  command -v efibootmgr >/dev/null 2>&1 || return 1
  local line num
  while IFS= read -r line; do
    case "$line" in
      Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
        if printf '%s' "$line" | grep -qiE 'Windows Boot Manager|bootmgfw\.efi'; then
          num="${line#Boot}"
          num="${num%%[^0-9A-Fa-f]*}"
          printf '%s\n' "$num"
          return 0
        fi
        ;;
    esac
  done < <(efibootmgr -v 2>/dev/null || true)
  return 1
}

grubenv_path() {
  local cfg
  cfg="$(find_grub_cfg || true)"
  if [ -n "$cfg" ] && [ -f "$(dirname "$cfg")/grubenv" ]; then
    printf '%s\n' "$(dirname "$cfg")/grubenv"
    return 0
  fi
  for candidate in /boot/grub/grubenv /boot/grub2/grubenv; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

grubenv_is_writable_at_boot() {
  # GRUB cannot reliably save_env on Btrfs/XFS (read-only drivers) → Windows boot loop.
  local env path fs
  env="$(grubenv_path || true)"
  [ -n "$env" ] || return 1
  path="$(dirname "$env")"
  fs="$(fstype_of_path "$path")"
  case "$fs" in
    vfat|fat|fat32|msdos|ext2|ext3|ext4) return 0 ;;
    *) return 1 ;;
  esac
}

grub_windows_entry() {
  local cfg
  cfg="$(find_grub_cfg || true)"
  [ -n "$cfg" ] || return 1
  awk -F"'" '
    /^[[:space:]]*menuentry / {
      if (tolower($2) ~ /windows/) { print $2; exit }
    }
  ' "$cfg"
}

limine_windows_entry() {
  local conf
  conf="$(find_limine_conf "${1:-}" || true)"
  [ -n "$conf" ] || return 1
  awk '
    /^[[:space:]]*\/.*[Ww]indows/ {
      name=$0
      sub(/^[[:space:]]*\//, "", name)
      print name
      exit
    }
  ' "$conf"
}

choose_oneshot_method() {
  local bootloader="$1"
  local bootnum="${2:-}"

  if [ "$bootloader" = "refind" ]; then
    printf '%s\n' "refind-conf"
    return 0
  fi
  if [ -n "$bootnum" ]; then
    printf '%s\n' "bootnext"
    return 0
  fi
  if [ "$bootloader" = "limine" ] || [ "$bootloader" = "systemd-boot" ]; then
    printf '%s\n' "loader-oneshot"
    return 0
  fi
  if [ "$bootloader" = "grub" ] && grubenv_is_writable_at_boot; then
    printf '%s\n' "grub-reboot"
    return 0
  fi
  printf '%s\n' "bootnext"
}

ensure_windows_esp_mounted_rw() {
  local dev="${1:-${WINDOWS_ESP_DEV:-}}"
  local existing

  if [ -z "$dev" ]; then
    dev="$(detect_windows_esp_dev || true)"
  fi
  [ -n "$dev" ] || return 1

  existing="$(mounted_target "$dev")"
  if [ -n "$existing" ]; then
    if touch "$existing/.omen-write-test" 2>/dev/null; then
      rm -f "$existing/.omen-write-test"
      printf '%s\n' "$existing"
      return 0
    fi
    # mounted read-only; still use it if we can remount
    if mount -o remount,rw "$existing" 2>/dev/null; then
      printf '%s\n' "$existing"
      return 0
    fi
  fi

  mkdir -p "$OMEN_ESP_MOUNTPOINT"
  if findmnt -n "$OMEN_ESP_MOUNTPOINT" >/dev/null 2>&1; then
    printf '%s\n' "$OMEN_ESP_MOUNTPOINT"
    return 0
  fi
  if mount -o rw "$dev" "$OMEN_ESP_MOUNTPOINT"; then
    printf '%s\n' "$OMEN_ESP_MOUNTPOINT"
    return 0
  fi
  return 1
}

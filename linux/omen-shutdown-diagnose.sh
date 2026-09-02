#!/usr/bin/env bash
# Collect facts that distinguish incomplete S5 (dGPU rail still on) from a clean power-off.
set -euo pipefail

echo "=== OMEN shutdown diagnose ==="
echo "date: $(date -Is 2>/dev/null || date)"
echo

if [ -r /sys/class/dmi/id/product_name ]; then
  echo "product: $(cat /sys/class/dmi/id/product_name 2>/dev/null) $(cat /sys/class/dmi/id/product_version 2>/dev/null)"
  echo "board:   $(cat /sys/class/dmi/id/board_name 2>/dev/null)"
  echo "bios:    $(cat /sys/class/dmi/id/bios_version 2>/dev/null) $(cat /sys/class/dmi/id/bios_date 2>/dev/null)"
fi
echo "kernel:  $(uname -r)"
echo

echo "=== ACPI sleep / power ==="
[ -r /sys/power/state ] && echo "state:     $(cat /sys/power/state)"
[ -r /sys/power/mem_sleep ] && echo "mem_sleep: $(cat /sys/power/mem_sleep)"
echo

echo "=== DSDT OEM / methods (strings) ==="
if [ -r /sys/firmware/acpi/tables/DSDT ]; then
  strings /sys/firmware/acpi/tables/DSDT 2>/dev/null | awk '
    /WQBZ|WQBE|PG00|GPTS|_PTS|PEGP|WBU1|WBU2/ { print }
  ' | sort -u | head -n 40
else
  echo "DSDT not readable (need root)."
fi
echo

echo "=== dmesg ACPI errors (this boot) ==="
if command -v dmesg >/dev/null 2>&1; then
  dmesg -T 2>/dev/null | grep -iE 'ACPI.*(error|bug|WQBZ|BUFFER_LIMIT|PEGP)|NVRM:.*DSM' | tail -n 30 || true
fi
echo

echo "=== NVIDIA PCI power ==="
if command -v lspci >/dev/null 2>&1; then
  lspci -d 10de: -vvv 2>/dev/null | grep -E 'VGA|3D|Kernel driver|D0|D3' | head -n 20 || true
fi
echo

echo "=== Last shutdown journal ==="
if command -v journalctl >/dev/null 2>&1; then
  journalctl -b -1 -n 40 --no-pager 2>/dev/null | grep -iE 'poweroff|reboot|omen-clean|Reached target' || true
fi
echo
if [ -f /var/log/omen-clean-shutdown.log ]; then
  echo "=== omen-clean-shutdown.log (tail) ==="
  tail -n 20 /var/log/omen-clean-shutdown.log || true
fi
echo

echo "=== Filesystems ==="
findmnt -n -o TARGET,FSTYPE,SOURCE / /boot /boot/efi /efi 2>/dev/null || true
echo

echo "=== Bootloader / EFI ==="
if [ -f /usr/local/lib/omen-clean-shutdown/omen-boot-lib.sh ]; then
  # shellcheck source=omen-boot-lib.sh
  . /usr/local/lib/omen-clean-shutdown/omen-boot-lib.sh
  if [ -f "$OMEN_ENV_FILE" ]; then
    echo "env: $OMEN_ENV_FILE"
    grep -E '^[A-Z_]+=' "$OMEN_ENV_FILE" || true
    echo
  fi
  efi_mount="$(detect_linux_efi_mount || true)"
  echo "linux efi/boot mount: ${efi_mount:-unknown}"
  echo "bootloader: $(detect_bootloader "$efi_mount")"
  echo "limine.conf: $(find_limine_conf "$efi_mount" || echo none)"
  echo "grub.cfg: $(find_grub_cfg || echo none)"
  echo "refind.conf: $(find_refind_conf_in "$efi_mount" || echo none)"
  echo "windows ESP: $(detect_windows_esp_dev || echo none)"
  echo "windows bootnum: $(detect_windows_bootnum || echo none)"
  ge="$(grubenv_path || true)"
  if [ -n "$ge" ]; then
    echo "grubenv: $ge on $(fstype_of_path "$(dirname "$ge")")"
    if grubenv_is_writable_at_boot; then
      echo "grub-reboot: allowed"
    else
      echo "grub-reboot: skipped (Btrfs/XFS/other — use BootNext)"
    fi
  fi
fi
if command -v efibootmgr >/dev/null 2>&1; then
  echo
  efibootmgr 2>/dev/null | head -n 20 || true
fi
echo

echo "=== Workaround files ==="
for p in /boot/efi /efi /boot /run/omen-windows-esp; do
  if [ -d "$p/EFI" ]; then
    echo "EFI mount candidate: $p"
    ls -l "$p/EFI/omen/shutdown_flag" "$p/EFI/refind/shutdown_flag" "$p/EFI/refind/refind.conf" "$p/limine.conf" 2>/dev/null || true
  fi
done
echo "native-poweroff flag: $( [ -e /etc/omen-native-poweroff ] && echo present || echo absent )"
echo
echo "If the chassis is still warm after Linux poweroff, the firmware did not reach S5."
echo "Do not bag the laptop until the power LED is off and the chassis is cold."

#!/usr/bin/env bash
set -euo pipefail

LIB="${OMEN_BOOT_LIB:-/usr/local/lib/omen-clean-shutdown/omen-boot-lib.sh}"
if [ -f "$LIB" ]; then
  # shellcheck source=omen-boot-lib.sh
  . "$LIB"
fi
if [ -f "${OMEN_ENV_FILE:-/etc/omen-clean-shutdown.env}" ]; then
  # shellcheck disable=SC1090
  . "${OMEN_ENV_FILE:-/etc/omen-clean-shutdown.env}"
fi

REFIND_SOURCE="${REFIND_SOURCE:-}"
REFIND_TARGET="${REFIND_TARGET:-}"

if [ -z "$REFIND_SOURCE" ] || [ ! -f "$REFIND_SOURCE" ]; then
  echo "Missing rEFInd source: ${REFIND_SOURCE:-unset}" >&2
  exit 0
fi

if [ -z "$REFIND_TARGET" ] || [ ! -f "$REFIND_TARGET" ]; then
  echo "Target ${REFIND_TARGET:-unset} does not exist, skipping rEFInd protection." >&2
  exit 0
fi

FILESIZE=$(stat -c%s "$REFIND_TARGET" 2>/dev/null || stat -f%z "$REFIND_TARGET" 2>/dev/null || echo 0)
if [ "$FILESIZE" -gt 1048576 ]; then
  cp -f "$REFIND_SOURCE" "$REFIND_TARGET"
fi

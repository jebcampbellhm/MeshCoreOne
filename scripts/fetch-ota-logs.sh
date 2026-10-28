#!/bin/bash
# Retrieve only the bounded OTA logs from an unlocked, paired development phone.
set -euo pipefail
device="${1:?Usage: bash scripts/fetch-ota-logs.sh DEVICE_ID [DESTINATION]}"
destination="${2:-/tmp/MC1OTA-logs-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$destination"
xcrun devicectl device copy from \
  --device "$device" \
  --domain-type appDataContainer \
  --domain-identifier com.jebcampbellhm.mc1ota \
  --source Library/Caches/MC1OTA-SessionLogs \
  --destination "$destination" \
  --timeout 30
printf 'OTA logs copied to %s\n' "$destination"

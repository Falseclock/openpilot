#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# On any failure, run the fallback launcher
trap 'exec ./launch_chffrplus.sh' ERR
C3_LAUNCH_SH="./sunnypilot/system/hardware/c3/launch_chffrplus.sh"

MODEL="$(tr -d '\0' < "/sys/firmware/devicetree/base/model")"
export MODEL

# WiFi regdomain US — runs for both comma 3 (tici) and comma 4 (mici)
# subshell + `|| true` is mandatory: set -e + ERR trap above would otherwise
# fall back to ./launch_chffrplus.sh on any failure, breaking the c3 path
(
  if ! command -v iw >/dev/null 2>&1; then
    # iw is not in stock AGNOS — auto-install it
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends iw
  fi
  command -v iw >/dev/null 2>&1 && sudo iw reg set US
) || true

if [ "$MODEL" = "comma tici" ]; then
  # Force a failure if the launcher doesn't exist
  [ -x "$C3_LAUNCH_SH" ] || false

  # If it exists, run it
  exec "$C3_LAUNCH_SH"
fi

exec ./launch_chffrplus.sh

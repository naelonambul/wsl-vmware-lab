#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "$0")" && pwd)
script=$(wslpath -w "$project/tcp-relay.ps1")
exec /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
  -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" "$1" "$2"

#!/usr/bin/env bash
# Download the official Ubuntu 24.04 (noble) server cloud image OVA into the
# repository and verify it: SHA256SUMS signature (gpgv) and the OVA checksum.
# Usage: bash download-ubuntu-image.sh   (re-running skips a verified download)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

base_url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current}"
ova_name="noble-server-cloudimg-amd64.ova"   # file name published by Ubuntu
keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
cd "$LAB_PROJECT_DIR"

curl -fsS -o SHA256SUMS "$base_url/SHA256SUMS"
curl -fsS -o SHA256SUMS.gpg "$base_url/SHA256SUMS.gpg"
if [[ -f "$keyring" ]]; then
  gpgv --keyring "$keyring" SHA256SUMS.gpg SHA256SUMS
  echo "[OK] SHA256SUMS signature verified with $keyring"
else
  echo "[WARN] $keyring missing (package ubuntu-cloudimage-keyring); signature NOT verified" >&2
fi

grep -q " \*\?${ova_name}\$" SHA256SUMS || { echo "[ERROR] $ova_name not listed in SHA256SUMS" >&2; exit 1; }
if [[ -f "$ova_name" ]] && sha256sum --ignore-missing -c SHA256SUMS 2>/dev/null | grep -q "^${ova_name}: OK$"; then
  echo "[OK] $ova_name already present and verified"
  exit 0
fi
curl -fSL --retry 3 -o "$ova_name.part" "$base_url/$ova_name"
mv "$ova_name.part" "$ova_name"
# Exactly one file is checked; sha256sum exits non-zero on mismatch.
sha256sum --ignore-missing -c SHA256SUMS
echo "[OK] $ova_name downloaded and verified"

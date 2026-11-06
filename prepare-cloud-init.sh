#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-config.sh"

seed_dir="${LAB_PROJECT_DIR}/cloud-init"
mkdir -p "${LAB_PRIVATE_DIR}" "${seed_dir}"
chmod 700 "${LAB_PRIVATE_DIR}"

if [[ ! -f "${LAB_SSH_KEY}" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'wsl-vmware-lab' -f "${LAB_SSH_KEY}"
fi
chmod 600 "${LAB_SSH_KEY}"

pubkey="$(cat "${LAB_SSH_KEY}.pub")"
# Guest user = the image's default user (see lib/cloud-config.sh).
{
  echo '#cloud-config'
  lab_cloud_config_users "$pubkey"
  echo 'package_update: false'
  echo 'package_upgrade: false'
  echo 'runcmd:'
  echo '  - [systemctl, enable, --now, ssh]'
  lab_cloud_config_runcmd
} > "${seed_dir}/user-data"

cat > "${seed_dir}/meta-data" <<'CFG'
instance-id: ubuntu-wsl-vmware-lab-001
local-hostname: ubuntu-wsl-lab
CFG

cloud-localds "${seed_dir}/seed.iso" "${seed_dir}/user-data" "${seed_dir}/meta-data"
chmod 644 "${seed_dir}/seed.iso"
echo "Cloud-init seed created: ${seed_dir}/seed.iso"
echo "SSH key stored in ${LAB_PRIVATE_DIR}"

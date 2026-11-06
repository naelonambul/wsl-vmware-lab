#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

seed_dir="${LAB_PROJECT_DIR}/cloud-init"
mkdir -p "${LAB_PRIVATE_DIR}" "${seed_dir}"
chmod 700 "${LAB_PRIVATE_DIR}"

if [[ ! -f "${LAB_SSH_KEY}" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C 'wsl-vmware-lab' -f "${LAB_SSH_KEY}"
fi
chmod 600 "${LAB_SSH_KEY}"

pubkey="$(cat "${LAB_SSH_KEY}.pub")"
# The image's "default" user is already "ubuntu"; list it only for other names.
default_entry=""
[[ "${LAB_GUEST_USER}" != ubuntu ]] && default_entry="  - default"
cat > "${seed_dir}/user-data" <<CFG
#cloud-config
users:
${default_entry}
  - name: ${LAB_GUEST_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
runcmd:
  - [systemctl, enable, --now, ssh]
CFG

cat > "${seed_dir}/meta-data" <<'CFG'
instance-id: ubuntu-wsl-vmware-lab-001
local-hostname: ubuntu-wsl-lab
CFG

cloud-localds "${seed_dir}/seed.iso" "${seed_dir}/user-data" "${seed_dir}/meta-data"
chmod 644 "${seed_dir}/seed.iso"
echo "Cloud-init seed created: ${seed_dir}/seed.iso"
echo "SSH key stored in ${LAB_PRIVATE_DIR}"

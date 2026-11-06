#!/usr/bin/env bash
set -euo pipefail

# Run with: sudo bash setup-wsl-tools.sh
# Install Terraform from HashiCorp's signed apt repository and Ansible plus
# cloud-image utilities from Ubuntu's repository.
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo: sudo bash setup-wsl-tools.sh" >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl gnupg

curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

. /etc/os-release
ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
architecture="$(dpkg --print-architecture)"
echo "deb [arch=${architecture} signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${ubuntu_codename} main" \
  > /etc/apt/sources.list.d/hashicorp.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  terraform ansible python3 qemu-utils cloud-image-utils genisoimage openssh-client

terraform version
ansible --version | head -n 2
qemu-img --version | head -n 1
cloud-localds --help >/dev/null
echo "cloud-localds ready"

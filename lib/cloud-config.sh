# shellcheck shell=bash
# Shared cloud-init user-data for clones. Source after lib/config.sh.
#
# Every clone gets a fixed guest user (LAB_GUEST_USER, lib/config.sh) that holds the lab key
# and may sudo without a password, and an SSH host key generated in WSL before
# its first boot (bootstrap-guest.sh). WSL therefore knows both before the
# guest runs, and connects only to a host holding that key, never to another VM
# that got an old DHCP address (guest-inventory.py). Nothing has to be reported
# from inside the guest, so the image needs no VMware Tools (open-vm-tools).

# Usage: lab_cloud_config_user_data "<lab public key line>" <host key file>
# Prints the whole #cloud-config. <host key file> is an OpenSSH ed25519 private
# key with <file>.pub next to it; both end up in the guest's /etc/ssh.
lab_cloud_config_user_data() {
  local pubkey=$1 hostkey=$2
  local keybody
  keybody=$(printf '%s\n' "$pubkey" | awk '{print $2}')
  [[ "$keybody" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo 'Unexpected SSH public key format' >&2; return 1; }
  cat <<CFG
#cloud-config
users:
  - name: ${LAB_GUEST_USER}
    lock_passwd: true
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
disable_root: true
# Replace whatever host keys the disk has with the one WSL already pinned.
ssh_deletekeys: true
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$hostkey")
  ed25519_public: $(cut -d' ' -f1,2 "$hostkey.pub")
# Give every new instance its own machine-id (a base booted by an older
# version of this lab carried one).
bootcmd:
  - [cloud-init-per, instance, wsl-vmware-lab-machine-id, sh, -c, 'rm -f /etc/machine-id && systemd-machine-id-setup']
package_update: false
package_upgrade: false
runcmd:
  - [systemctl, enable, --now, ssh]
CFG
}

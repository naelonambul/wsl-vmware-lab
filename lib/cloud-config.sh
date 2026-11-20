# shellcheck shell=bash
# Shared cloud-init user-data for clones. Source after lib/config.sh.
#
# Every clone gets a fixed guest user (LAB_GUEST_USER, lib/config.sh) that holds the lab key
# and may sudo without a password, and an SSH host key generated in WSL before
# its first boot (bootstrap-guest.sh). WSL therefore knows both before the
# guest runs, and connects only to a host holding that key, never to another VM
# that got an old DHCP address (guest-inventory.py). Nothing has to be reported
# from inside the guest, so the image needs no VMware Tools (open-vm-tools).

# Usage: lab_cloud_config_user_data "<lab public key line>" <host key file> [image] [lan] [lan_mac]
# Prints the whole #cloud-config. <host key file> is an OpenSSH ed25519 private
# key with <file>.pub next to it; both end up in the guest's /etc/ssh.
lab_cloud_config_user_data() {
  local pubkey=$1 hostkey=$2 image=${3:-} lan=${4:-none} lan_mac=${5:-}
  local keybody host_private host_public
  keybody=$(printf '%s\n' "$pubkey" | awk '{print $2}') || return 1
  [[ "$keybody" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo 'Unexpected SSH public key format' >&2; return 1; }
  host_private=$(sed 's/^/    /' "$hostkey") || return 1
  host_public=$(cut -d' ' -f1,2 "$hostkey.pub") || return 1
  [[ -n "$host_private" && -n "$host_public" ]] || return 1
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
$host_private
  ed25519_public: $host_public
# Give every new instance its own machine-id (a base booted by an older
# version of this lab carried one).
bootcmd:
  - [cloud-init-per, instance, wsl-vmware-lab-machine-id, sh, -c, 'rm -f /etc/machine-id && systemd-machine-id-setup']
CFG
  if [[ "$image" == oraclelinux-8 ]]; then
    lan_mac="${lan_mac,,}"
    if [[ "$lan" != none ]]; then
      [[ "$lan" == dhcp || "$lan" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { echo 'Unexpected LAN setting for oraclelinux-8' >&2; return 1; }
      [[ "$lan_mac" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || { echo 'Unexpected LAN MAC for oraclelinux-8' >&2; return 1; }
    fi
    cat <<CFG
# Oracle Linux 8 KVM cloud image omits VMware NIC modules from kernel-uek-core.
# Install the matching kernel-uek-modules RPM from the read-only OL8MODS ISO,
# load vmxnet3, and bring up all interfaces via NetworkManager.
runcmd:
  - |
    set -eu
    if ! modinfo vmxnet3 >/dev/null 2>&1; then
      trap 'umount /mnt/ol8mods 2>/dev/null || true; rmdir /mnt/ol8mods 2>/dev/null || true' EXIT
      mkdir -p /mnt/ol8mods
      mount -o ro /dev/disk/by-label/OL8MODS /mnt/ol8mods
      rpm -ivh --nodeps /mnt/ol8mods/kernel-uek-modules-*.rpm
      umount /mnt/ol8mods
      rmdir /mnt/ol8mods
      trap - EXIT
      depmod -a
    fi
    modprobe vmxnet3
    udevadm settle || true
    lan='${lan}'
    lan_mac='${lan_mac}'
    for path in /sys/class/net/*; do
      dev=\${path##*/}
      [ "\$dev" != "lo" ] || continue
      [ -f "\$path/type" ] && [ "\$(cat "\$path/type")" = "1" ] || continue
      mac=\$(tr '[:upper:]' '[:lower:]' < "\$path/address")
      if [ "\$lan" != "none" ] && [ "\$mac" = "\$lan_mac" ]; then
        nmcli con show lan0 >/dev/null 2>&1 && nmcli con delete lan0 || true
        if [ "\$lan" = "dhcp" ]; then
          nmcli con add type ethernet con-name lan0 ifname "\$dev" ethernet.mac-address "\$lan_mac" ipv4.method auto ipv4.never-default yes ipv4.ignore-auto-dns yes connection.autoconnect yes connection.autoconnect-priority 100
        else
          nmcli con add type ethernet con-name lan0 ifname "\$dev" ethernet.mac-address "\$lan_mac" ipv4.method manual ipv4.addresses "\$lan" ipv4.never-default yes ipv4.ignore-auto-dns yes connection.autoconnect yes connection.autoconnect-priority 100
        fi
        nmcli con up lan0
      else
        nmcli device connect "\$dev" || true
      fi
    done
CFG
  fi
}

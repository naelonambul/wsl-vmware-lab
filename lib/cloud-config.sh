# Shared cloud-init user-data for the base VM and clones. Source after lib/config.sh.
#
# The guest user is not configured: cloud-init keeps the image's default user
# ("ubuntu" on Ubuntu cloud images) and top-level ssh_authorized_keys go to that
# user. On every boot a small unit reports the name of the user that holds the
# lab key through VMware guestinfo, so WSL can read it with
#   vmrun readVariable <vmx> guestVar wsl-vmware-lab.guest_user
# instead of assuming a name.

LAB_GUESTINFO_USER_VAR=wsl-vmware-lab.guest_user

# Usage: lab_cloud_config_users "<public key line>"
lab_cloud_config_users() {
  local pubkey=$1
  local keybody
  keybody=$(printf '%s\n' "$pubkey" | awk '{print $2}')
  [[ "$keybody" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo 'Unexpected SSH public key format' >&2; return 1; }
  cat <<CFG
users:
  - default
ssh_authorized_keys:
  - ${pubkey}
ssh_pwauth: false
disable_root: true
write_files:
  - path: /usr/local/sbin/wsl-vmware-lab-guestinfo
    permissions: '0755'
    content: |
      #!/bin/sh
      # Report the user that holds the lab SSH key to the VMware host.
      found=\$(getent passwd | awk -F: '\$3 >= 1000 && \$3 < 60000 {print \$1 ":" \$6}' |
        while IFS=: read -r user home; do
          if grep -qsF '${keybody}' "\$home/.ssh/authorized_keys"; then
            echo "\$user"; break
          fi
        done)
      [ -n "\$found" ] || exit 1
      exec vmware-rpctool "info-set guestinfo.${LAB_GUESTINFO_USER_VAR} \$found"
  - path: /etc/systemd/system/wsl-vmware-lab-guestinfo.service
    content: |
      [Unit]
      Description=Report the lab guest user through VMware guestinfo
      After=open-vm-tools.service
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/wsl-vmware-lab-guestinfo
      [Install]
      WantedBy=multi-user.target
CFG
}

# Runcmd lines (indented for the runcmd list) that enable the unit. On later boots
# the unit runs by itself; the user already exists then. Do not order the unit
# after cloud-final.service: that unit is ordered after multi-user.target, so the
# cycle makes systemd drop cloud-final on reboot and `cloud-init status --wait`
# never returns. On first boot runcmd (inside cloud-final) starts it once the
# user exists; --no-block keeps runcmd from waiting on it.
lab_cloud_config_runcmd() {
  cat <<'CFG'
  - [systemctl, daemon-reload]
  - [systemctl, enable, wsl-vmware-lab-guestinfo.service]
  - [systemctl, start, --no-block, wsl-vmware-lab-guestinfo.service]
CFG
}

# Read VMware networks before setup or up

Run `./lab network` in each checkout before setup or any up. It reads Windows
evidence and local VMXs, with no vmrest, credentials, lock or Terraform init.
Keep host-specific results in private project notes, never this public repo.
Status also reports each state's VM instance's desired/actual ethernet2 beside
its live power. Neither command repairs anything.

## What to record

- VMnet0, VMnet1, VMnet8 first, then every other VMnet: netmap names, subnet,
  Adapter/UseAdapter, DHCP/UseDHCP, NAT/UseNAT, NAT TCP forwards and raw values.
- The primary 64-bit registry view of
  `HKLM\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig`; the 32-bit view is
  supplementary reported evidence. Also record
  `HKLM\SYSTEM\CurrentControlSet\Services\VMnetBridge\Parameters\Adapters`
  (including subkeys). SYSTEM keys may be shared between views; do not count
  duplicate evidence as another network.
- Adapters' names, descriptions, status, virtual/physical evidence, IP
  configuration, and hidden VMware Bridge Protocol bindings.
- Configured NAT, management and effective LAN roles; each existing base's
  `ethernet0.vnet` versus `LAB_NAT_VNET`; clone ethernet2 desired versus actual.

The conventional defaults are VMnet0 Bridged, VMnet1 Host-only, VMnet8 NAT;
their numbers do not prove their roles on this host. Missing keys, values or
access are null with reasons, never defaults. The collector counts named values
in `NAT\TCP` as forwarding entries and retains raw subkeys as flat records
with path, values and reason (inside each raw evidence array): confirm this
layout in the installed Workstation version. Do not infer zero forwards from
missing evidence. Compare with the Virtual Network Editor **view only** when
the registry layout differs. Never restore VMware network defaults.

Bridge bindings identify candidate adapters, not the physical adapter selected
by Automatic. If that selection is unresolved, show the fresh evidence and ask
the user before enabling `lan`. Do not change bindings to discover it.

## When the wrapper cannot run

Read this file, then run the read-only Windows action:

```powershell
.\windows\setup.cmd Network
```

If the collector is unavailable, collect the equivalent evidence directly:

```powershell
[System.IO.File]::ReadAllText("$env:ProgramData\VMware\netmap.conf")
reg.exe query "HKLM\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig" /s /reg:64
reg.exe query "HKLM\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig" /s /reg:32
reg.exe query HKLM\SYSTEM\CurrentControlSet\Services\VMnetBridge\Parameters\Adapters /s /reg:64
reg.exe query HKLM\SYSTEM\CurrentControlSet\Services\VMnetBridge\Parameters\Adapters /s /reg:32
Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceDescription,Status,Virtual,HardwareInterface
Get-NetAdapter -Physical
Get-NetIPConfiguration -All
Get-NetAdapterBinding -IncludeHidden -ComponentID vmware_bridge
```

Record errors as missing evidence. These commands need no elevation for normal
read access. Do not substitute `setup.cmd Install`: it changes boot tasks,
legacy launchers, SSH firewall rules, power policy and bridge bindings.

## Select roles and handle mismatches

`LAB_LAN_VNET` empty or `VMnet0` means `connectionType = "bridged"` with no
`ethernet2.vnet`. `VMnet1` through `VMnet19` means `custom` plus that vnet.
The effective LAN VMnet must differ from `LAB_NAT_VNET` and `LAB_MGMT_VNET`;
invalid settings fail with `config_error` (exit 2) before host discovery.
This setting is not a Terraform replacement trigger: it never rebuilds clones.

Any clone with `ethernet2.present = "TRUE"` whose connection/vnet differs blocks
all up variants with `lan_vnet_mismatch` (exit 5), listing desired and actual.
Down, status, network, configure and destroy remain available. There is no
bypass or stored confirmation. An unreadable VMX also refuses up because its
wiring cannot be established. Ask the user whether to revert `LAB_LAN_VNET` or
repair the existing VMX offline.

NAT is baked into each base VMX. A changed `LAB_NAT_VNET` needs
`setup --recreate` plus rebuilt clones, losing their contents. Show the base
difference and ask the user before that destructive path.

## Offline LAN VMX repair (only after the user chooses it)

1. Power the affected VM off with the wrapper. Confirm **both** vmrest reports
   `poweredOff` and Workstation's `vmrun -T ws list` omits the VMX. Unknown or
   contradictory power means stop. Do not edit a running VM.
2. Copy the VMX to a backup outside version control.
3. Edit only `ethernet2.connectionType` and `ethernet2.vnet`: custom plus the
   chosen VMnet, or bridged and **remove** `ethernet2.vnet` for VMnet0.
4. Preserve `ethernet2.addressType` and `ethernet2.address`; cloud-init matches
   this MAC to `lan0`. Never rerun bootstrap on an existing disk.
5. Run `./lab status` and `./lab network`, compare desired/actual, then follow
   the system's documented start order. A config change alone is not repair.

## Sources and verification limits

Use the installed Workstation Help's Virtual Network Editor, bridged networking
and custom networking sections, available via
[Broadcom Workstation documentation](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro.html).
Registry storage and Automatic selection need real-host verification against
that version; raw values are evidence, not a universal registry contract.
Microsoft documents the read-only adapter and binding cmdlets in
[NetAdapter](https://learn.microsoft.com/en-us/powershell/module/netadapter/)
and IP configuration in
[NetTCPIP](https://learn.microsoft.com/en-us/powershell/module/nettcpip/).

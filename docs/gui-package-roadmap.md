# Dusky Flint 3 GUI Package Roadmap

The Dusky build is GUI-first. A user-facing feature is not complete merely
because its backend package is present. Normal setup, status, error handling,
and recovery must be available through LuCI or Footstrap.

`config/dusky-full.packages` is also the complete validated package baseline.
It explicitly lists hardware support, filesystems, NAS, DNS, SQM, ZRAM, and
management packages required by the known-good Flint 3 setup. It is not limited
to top-level LuCI applications.

## Package states

- **Enabled**: selected by `config/dusky-full.packages` and validated in CI.
- **Verified next**: upstream package and GUI exist, but runtime integration is
  not yet tested on the Flint 3.
- **Custom GUI required**: backend exists, but the required user experience
  needs a Dusky LuCI application or Footstrap page.
- **Unresolved**: package/provider choice still needs investigation.

## Enabled baseline

| Feature | Packages | GUI source | Remaining work |
|---|---|---|---|
| Firewall | `luci-app-firewall` | Upstream LuCI | Footstrap summaries and lockout warnings |
| SQM/CAKE | `luci-app-sqm`, CAKE, IFB, `tc-tiny`, `sqm-scripts` | Upstream LuCI | Presets, active qdisc status, offload conflict handling |
| USB storage | DWC3 QCOM, xHCI, USB storage, UAS, block-mount | Native LuCI status plus Footstrap | Port status, safe eject, and clearer hardware errors |
| Filesystems | EXT4, exFAT, NTFS3, VFAT and required NLS modules | Footstrap required | Format, label, UUID mount, health, and repair workflows |
| SMB/NAS | `kmod-fs-ksmbd`, `ksmbd-server`, `luci-app-ksmbd`, `wsdd2`, `umdns` | Upstream LuCI plus Footstrap | Drive, user, share, permission, discovery, and safe-eject wizard |
| DNS proxy | `dnsproxy`, `ca-bundle`, `ca-certificates` | Footstrap required | Preserve the dnsmasq-to-`127.0.0.1#5453` architecture, provider setup, status, and leak tests |
| ZRAM | `kmod-zram`, `kmod-lib-lzo`, `zram-swap` | Footstrap status | Usage, compression, and failure visibility |
| WireGuard | `luci-proto-wireguard` | Upstream LuCI | Import, server/client wizard, status, kill switch |
| Policy routing | `luci-app-pbr` | Upstream LuCI | Device picker, simple policies, VPN fallback controls |
| Multi-WAN | `luci-app-mwan3` | Upstream LuCI | Failover presets, health status, SQM/VPN coordination |

## Deliberate replacements and exclusions

- The build uses **ksmbd**, not Samba 4. Installing both SMB servers is
  forbidden by CI.
- The build uses **dnsproxy**, not the separate `nextdns` daemon. This preserves
  the known-good local proxy architecture and prevents competing resolver
  services.
- `kmod-usb-dwc3-of-simple` remains disabled. The flattened IPQ5332 controller
  binds through `dwc3-qcom`.
- The IPQ5332 USB PHY is not an installable
  `kmod-phy-qcom-uniphy-usb` package in this tree. It is the built-in kernel
  driver `CONFIG_PHY_QCOM_M31_USB=y`, which the build validates directly.

## NAS configuration target

The restored router configuration is expected to mount the existing EXT4
partition persistently by UUID at:

```text
/mnt/nas
```

The package build supplies all required USB, block, EXT4, NLS, ksmbd, and
network-discovery components. The actual UUID, share definitions, credentials,
and permissions remain configuration data and must come from the router backup
or a device-specific restore operation; they are not hardcoded into a public
firmware image.

## Verified next candidates

These should be enabled one group at a time after the baseline compiles and
passes device testing:

| Feature | Candidate packages | Required checks |
|---|---|---|
| Alternate encrypted DNS | `luci-app-https-dns-proxy` | Must replace, not compete with, the active dnsproxy path |
| Dynamic DNS | `luci-app-ddns` | Provider list and simple custom-provider workflow |
| Repeater/travel mode | `luci-app-travelmate` | ath12k/MLO behavior and management rollback |
| Bandwidth accounting | `luci-app-nlbwmon` | Storage use and per-device presentation |
| Historical traffic | `luci-app-vnstat2` | Persistent database placement and flash writes |
| DLNA | `luci-app-minidlna` | `/mnt/nas` integration and disabled-by-default state |
| Drive idle control | `luci-app-hd-idle` | USB enclosure compatibility |
| Watchdog | `luci-app-watchcat` | Safe defaults and false-positive handling |
| Wi-Fi schedules | `luci-app-wifischedule` | MLO and multi-radio behavior |
| Wake-on-LAN | `luci-app-wol` | Interface and broadcast selection |
| UPnP | `luci-app-upnp` | nftables backend; installed but disabled by default |

## Custom GUI required

| Feature | Backend direction | Required Dusky work |
|---|---|---|
| Footstrap | Custom LuCI theme | Default navigation, responsive design, consistent forms |
| Main dashboard | ubus/UCI/service status | WAN, Wi-Fi, SQM, VPN, DNS, storage, clients, faults |
| First-boot setup | Standard OpenWrt services | Guided safe setup with rollback |
| dnsproxy manager | `dnsproxy` | Upstream selection, port ownership, status, logs, and leak tests |
| AdGuard Home | `adguardhome` native web UI | Explicit alternate DNS mode and port arbitration |
| ZeroTier | `zerotier` | Join/leave, network status, routes, bridge warnings |
| OpenVPN | `openvpn-openssl` | Select maintained GUI source or build Dusky UI; import first |
| VPN kill switches | firewall4, PBR, tunnel state | IPv4/IPv6/DNS-safe policy with emergency LAN access |
| Storage setup | block-mount, ksmbd, filesystem tools | Format, UUID mount, users, shares, permissions, safe eject |
| Network modes | netifd, firewall4, dnsmasq, travelmate | Router/AP/repeater workflows with timed rollback |
| DNS mode manager | dnsmasq plus selected resolver | Ensure exactly one authoritative client DNS path |
| Compatibility engine | UCI and service-state checks | Block or warn about unsafe feature combinations |
| Firmware updates | Existing builder and GitHub releases | Dusky release channel, metadata, validation, rollback |
| Support bundle | Standard diagnostics | Privacy-filtered downloadable logs and configuration state |

## Compatibility rules to enforce

1. Hardware flow offloading must not remain active with SQM.
2. Only one DNS architecture may own the client resolver path.
3. `dnsproxy` and `nextdns` must not be selected together.
4. ksmbd and Samba 4 must not be selected together.
5. MLO SSIDs must not enable 802.11r while the current hostapd limitation
   remains.
6. Guest networks must not gain SMB access by default.
7. VPN kill switches must cover IPv4, IPv6, and DNS.
8. Multi-WAN failover must not silently bypass a required VPN.
9. Repeater and multi-WAN configurations must attach SQM to the correct
   ingress and egress interfaces.
10. Potentially destructive network changes must support rollback.

## Build enforcement

The build performs these steps:

1. Fetch the exact pinned Perceival source commit.
2. Verify the IPQ5332 M31 USB PHY is built into the kernel configuration.
3. Apply and verify the USB PHY-mux and GPIO 16 VBUS pinctrl fix.
4. Install OpenWrt feeds.
5. Copy `config.seed` to `.config`.
6. Apply the complete `config/dusky-full.packages` baseline.
7. Run `make defconfig`.
8. Fail if any requested package symbol is missing, disabled, or resolves to
   an unexpected value.
9. Fail if the generic DWC3 driver, Samba 4, or the separate NextDNS daemon is
   selected.
10. Build the firmware and publish the requested manifest, full config,
    diffconfig, images, and checksums.

A package is added only after its identity is verified and its service role is
compatible with the rest of the firmware architecture.

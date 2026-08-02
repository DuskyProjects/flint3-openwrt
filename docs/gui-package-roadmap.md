# Dusky Flint 3 GUI Package Roadmap

The Dusky build is GUI-first. A user-facing feature is not complete merely
because its backend package is present. Normal setup, status, error handling,
and recovery must be available through LuCI or Footstrap.

## Package states

- **Enabled**: selected by `config/dusky-full.packages` and validated in CI.
- **Verified next**: upstream package and GUI exist, but runtime integration is
  not yet tested on the Flint 3.
- **Custom GUI required**: backend exists, but the required user experience
  needs a Dusky LuCI application or Footstrap page.
- **Unresolved**: package/provider choice still needs investigation.

## Enabled first tranche

| Feature | Package | GUI source | Remaining work |
|---|---|---|---|
| Firewall | `luci-app-firewall` | Upstream LuCI | Footstrap summaries and lockout warnings |
| SQM/CAKE | `luci-app-sqm` | Upstream LuCI | Presets, active qdisc status, offload conflict handling |
| SMB | `luci-app-samba4` | Upstream LuCI | Drive, user, share, permission, and safe-eject wizard |
| WireGuard | `luci-proto-wireguard` | Upstream LuCI | Import, server/client wizard, status, kill switch |
| Policy routing | `luci-app-pbr` | Upstream LuCI | Device picker, simple policies, VPN fallback controls |
| NextDNS | `luci-app-nextdns` | Upstream LuCI | DNS-mode coordinator and leak tests |
| Multi-WAN | `luci-app-mwan3` | Upstream LuCI | Failover presets, health status, SQM/VPN coordination |

Dependencies are selected by OpenWrt. The manifest intentionally lists the
user-facing top-level package instead of manually duplicating every dependency.

## Verified next candidates

These should be enabled one group at a time after the first tranche compiles:

| Feature | Candidate packages | Required checks |
|---|---|---|
| Encrypted DNS | `luci-app-https-dns-proxy` | Coexistence with NextDNS and PBR domain policies |
| Dynamic DNS | `luci-app-ddns` | Provider list and simple custom-provider workflow |
| Repeater/travel mode | `luci-app-travelmate` | ath12k/MLO behavior and management rollback |
| Bandwidth accounting | `luci-app-nlbwmon` | Storage use and per-device presentation |
| Historical traffic | `luci-app-vnstat2` | Persistent database placement and flash writes |
| DLNA | `luci-app-minidlna` | USB mount integration and disabled-by-default state |
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
| AdGuard Home | `adguardhome` native web UI | Service launch/status and DNS-port arbitration |
| ZeroTier | `zerotier` | Join/leave, network status, routes, bridge warnings |
| OpenVPN | `openvpn-openssl` | Select maintained GUI source or build Dusky UI; import first |
| VPN kill switches | firewall4, PBR, tunnel state | IPv4/IPv6/DNS-safe policy with emergency LAN access |
| Storage setup | block-mount, Samba, filesystem tools | Format, mount, users, shares, permissions, safe eject |
| Network modes | netifd, firewall4, dnsmasq, travelmate | Router/AP/repeater workflows with timed rollback |
| DNS mode manager | dnsmasq plus selected resolver | Ensure exactly one authoritative client DNS path |
| Compatibility engine | UCI and service-state checks | Block or warn about unsafe feature combinations |
| Firmware updates | Existing builder and GitHub releases | Dusky release channel, metadata, validation, rollback |
| Support bundle | Standard diagnostics | Privacy-filtered downloadable logs and configuration state |

## Compatibility rules to enforce

1. Hardware flow offloading must not remain active with SQM.
2. Only one DNS architecture may own the client resolver path.
3. MLO SSIDs must not enable 802.11r while the current hostapd limitation
   remains.
4. Guest networks must not gain SMB access by default.
5. VPN kill switches must cover IPv4, IPv6, and DNS.
6. Multi-WAN failover must not silently bypass a required VPN.
7. Repeater and multi-WAN configurations must attach SQM to the correct
   ingress and egress interfaces.
8. Potentially destructive network changes must support rollback.

## Build enforcement

The build performs these steps:

1. Install OpenWrt feeds.
2. Copy `config.seed` to `.config`.
3. Apply `config/dusky-full.packages`.
4. Run `make defconfig`.
5. Fail if any requested package symbol is missing, disabled, or resolves to
   an unexpected value.
6. Build the firmware.
7. Publish the requested manifest, full config, and diffconfig with artifacts.

A package is added to the enabled manifest only after its package identity is
verified and its GUI strategy is known.

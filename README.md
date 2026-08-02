# Dusky Flint 3 OpenWrt

A GUI-first, full-featured OpenWrt firmware project for the **GL.iNet Flint 3 (GL-BE9300)**.

The goal is to provide the useful capabilities and ease of use expected from GL.iNet firmware while using a transparent, maintainable OpenWrt base instead of GL.iNet's modified firmware stack.

This is not intended to be a minimal router image. It is intended to become a complete router distribution that ordinary users can configure safely through a clear web interface, while retaining normal OpenWrt access for advanced users.

> **Development status:** experimental and not yet ready for normal router use. The current branch establishes the package, validation, and build foundation. Footstrap and the guided management applications are still under development.

## Project goals

The completed Dusky build should provide:

- stock OpenWrt services and configuration wherever possible;
- Flint 3 hardware support from Perceival's OpenWrt work;
- broad functional parity with the useful local features of GL.iNet firmware;
- a polished, responsive LuCI interface using the **Footstrap** theme;
- GUI-driven setup for routine tasks without requiring SSH;
- safe presets, input validation, understandable errors, and rollback for disruptive changes;
- reproducible builds with pinned source revisions, package validation, logs, manifests, and checksums;
- documented upgrade, backup, recovery, and return-to-stock procedures.

The project is not trying to reproduce GL.iNet's proprietary interface, cloud services, account system, mobile application, or closed background services.

## GUI-first policy

A backend package is not considered a complete feature merely because it compiles or is installed.

A user-facing feature must eventually provide:

- setup and normal operation through LuCI or Footstrap;
- plain-language descriptions and recommended defaults;
- visible service and connection status;
- useful error reporting;
- validation before settings are applied;
- protection against incompatible settings;
- backup, restore, and upgrade behavior;
- access to the native advanced LuCI page when appropriate.

SSH and manual UCI editing remain available for troubleshooting and expert use, but they are not the intended primary workflow.

## Intended feature set

### Traffic management

- SQM and CAKE;
- guided bandwidth configuration;
- gaming, voice, balanced, and custom presets;
- active queue status;
- protection against enabling incompatible hardware flow offloading.

### Storage and file sharing

- USB storage detection and persistent mounting;
- EXT4, exFAT, NTFS, and FAT support where validated;
- Samba 4 SMB file sharing;
- user, password, share, permission, and read-only controls;
- modern SMB discovery;
- safe eject and storage-health information;
- LAN-only access by default.

### VPN and routing

- WireGuard client and server workflows;
- OpenVPN client and server workflows;
- profile import and export;
- policy-based routing by device, subnet, destination, or guest network;
- IPv4, IPv6, and DNS-aware kill switches;
- multiple tunnel profiles and visible tunnel state;
- Tailscale and ZeroTier integration after their GUI workflows are complete.

### DNS and filtering

- NextDNS integration;
- optional AdGuard Home mode;
- optional encrypted-DNS providers;
- local hostname resolution through dnsmasq;
- DNS leak testing;
- an interface that ensures only one DNS architecture controls client requests at a time.

### WAN and network modes

- multi-WAN and automatic failover;
- health checks and failback;
- router, access point, repeater, and bridge-oriented workflows where supported;
- guest networks;
- firewall, VLAN, DHCP, IPv6, port-forwarding, and traffic-rule management;
- guarded application and rollback for settings that could make the router unreachable.

### Monitoring and maintenance

- per-device traffic accounting;
- WAN, Wi-Fi, VPN, DNS, SQM, storage, temperature, memory, and fault status;
- diagnostics and privacy-filtered support bundles;
- configuration backup and restore;
- custom firmware update metadata and recovery guidance;
- ramoops/pstore crash-log support.

## Footstrap

**Footstrap** is the planned default LuCI theme and product interface for this firmware.

It is expected to provide:

- a responsive desktop and mobile layout;
- consistent navigation and terminology;
- a unified router dashboard;
- guided first-boot setup;
- simplified SQM, VPN, DNS, storage, and multi-WAN workflows;
- cross-feature compatibility warnings;
- links to full native LuCI pages for advanced configuration.

Footstrap is not yet present in the current image. The current work establishes the validated OpenWrt package layer that Footstrap will manage.

## Current implementation

The first GUI-backed feature tranche currently requests and validates:

| Feature | OpenWrt package |
|---|---|
| Firewall management | `luci-app-firewall` |
| SQM and CAKE | `luci-app-sqm` |
| Samba 4 network shares | `luci-app-samba4` |
| WireGuard configuration | `luci-proto-wireguard` |
| Policy-based routing | `luci-app-pbr` |
| NextDNS | `luci-app-nextdns` |
| Multi-WAN | `luci-app-mwan3` |

OpenWrt resolves their backend dependencies. The build fails if a requested package is missing, renamed, disabled, or does not survive `make defconfig`.

See [`docs/gui-package-roadmap.md`](docs/gui-package-roadmap.md) for the enabled package group, the next packages under consideration, custom GUI requirements, and compatibility rules.

## Source policy

The firmware source is pinned to:

- repository: `perceival/openwrt-flint3`;
- branch: `flint3-be9300`;
- exact commit: recorded in [`build.env`](build.env).

Perceival's repository is the sole OpenWrt hardware-support base for this project.

This repository does not combine multiple complete Flint 3 source trees. External changes may only be imported individually when their purpose, source, dependencies, licensing, and compatibility are understood.

The build currently adds:

- the Dusky package configuration and GUI-first manifest;
- package-application and validation scripts;
- Flint 3 USB PHY-mux fixes under `patches/`;
- the required backports source preparation helper;
- reproducible build and GitHub Actions workflows;
- release artifacts, checksums, resolved configuration, and package metadata.

## Compatibility rules

The firmware must actively detect, prevent, or clearly warn about unsafe combinations, including:

- SQM with hardware flow offloading;
- multiple DNS services competing for the client resolver path;
- MLO SSIDs using 802.11r while the current hostapd limitation remains;
- guest networks gaining SMB access by default;
- VPN kill switches that fail to cover IPv6 or DNS;
- multi-WAN failover bypassing a required VPN;
- SQM being attached to the wrong interface in repeater or multi-WAN configurations;
- network changes that could remove management access without rollback.

## Building

GitHub Actions is the preferred build environment. Development branches are tested through draft pull requests; only `main` may publish firmware prereleases.

A local build can be started with:

```bash
bash scripts/build.sh
```

The build process:

1. fetches the exact pinned Perceival commit;
2. applies the tracked Flint 3 patches;
3. installs OpenWrt feeds;
4. copies `config.seed` into the source tree;
5. applies `config/dusky-full.packages`;
6. runs `make defconfig`;
7. validates every requested package symbol;
8. downloads and compiles the firmware;
9. verifies that required images exist and are non-empty;
10. exports firmware, checksums, package requests, full configuration, and diffconfig.

Successful builds create files under `release/`, including:

- `flint3-full-factory.bin`;
- `flint3-sysupgrade.bin`;
- `SHA256SUMS`;
- `REQUESTED_PACKAGES`;
- `openwrt-full.config`;
- `openwrt-diffconfig`.

## Safety

This is development firmware for a device whose OpenWrt hardware support is still evolving.

Before flashing any image:

- back up the Flint 3 eMMC and calibration data;
- retain a known-good recovery image;
- understand the factory and sysupgrade installation paths;
- verify the SHA256 checksum;
- confirm that the build is associated with the intended source and builder commits;
- do not treat a successful compilation as proof that every feature is safe on hardware.

No stable release should be declared until Ethernet, all Wi-Fi radios, MLO, USB storage, SQM, firewalling, DNS, VPN routing, SMB, upgrade, and recovery behavior have passed device testing.

## Project boundaries

This project does not provide or intend to provide:

- GL.iNet GoodCloud compatibility;
- GL.iNet account or mobile-app integration;
- GL.iNet's proprietary web interface or service daemons;
- bundled passwords, VPN credentials, NextDNS identifiers, private keys, or personal configuration;
- automatic flashing after every build;
- support for router models other than the GL.iNet Flint 3 unless explicitly added later.

## Repository history

The repository state before the Perceival-only source reset is preserved on:

`backup/pre-perceival-reset-2026-08-01`

## Attribution

Flint 3 hardware enablement is based on Perceival's `openwrt-flint3` work and the upstream OpenWrt ecosystem. This project is independent and is not affiliated with or endorsed by GL.iNet or the OpenWrt project.
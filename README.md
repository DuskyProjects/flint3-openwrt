# Dusky Flint 3 OpenWrt

A GUI-first, full-featured OpenWrt firmware project for the **GL.iNet Flint 3
(GL-BE9300)**.

The goal is to provide the useful local capabilities and ease of use expected
from GL.iNet firmware while using a transparent and maintainable OpenWrt base.
This is not a minimal image. It is intended to become a complete router
firmware that can be managed safely through a polished web interface while
retaining normal OpenWrt access for advanced users.

> **Status:** experimental development firmware. Ethernet, Wi-Fi, MLO and
> sysupgrade are functional in the Perceival base, but the Dusky package set,
> USB/NAS behavior, GUI workflows, upgrade process and recovery path are still
> being validated on hardware.

## Source policy

The OpenWrt source tree is pinned to:

- repository: `perceival/openwrt-flint3`;
- branch: `flint3-be9300`;
- exact commit: recorded in [`build.env`](build.env).

Perceival's repository is the sole Flint 3 hardware-support base. This project
does not merge another complete Flint 3 source tree on top of it. Individual
external changes may be imported only when their purpose, dependencies,
licensing and compatibility are understood.

## Project goals

The completed firmware should provide:

- stock OpenWrt services and UCI configuration wherever possible;
- full Flint 3 Ethernet, Wi-Fi 7, MLO, USB and eMMC support;
- a polished LuCI interface using the planned **Footstrap** theme;
- GUI-driven setup for routine router, SQM, VPN, DNS and NAS tasks;
- safe presets, validation, understandable errors and rollback;
- reproducible builds with pinned source revisions and validated packages;
- documented backup, upgrade, recovery and return-to-stock procedures.

The project does not attempt to reproduce GL.iNet GoodCloud, account services,
mobile-app integration, proprietary service daemons or the proprietary GL.iNet
web interface.

## GUI-first policy

A package is not considered a completed feature merely because it compiles.
A normal user-facing feature must eventually provide:

- setup and operation through LuCI or Footstrap;
- recommended defaults and plain-language help;
- visible service and connection status;
- input validation and useful errors;
- protection against incompatible settings;
- backup, restore and upgrade behavior;
- access to the native advanced LuCI page where appropriate.

SSH and manual UCI editing remain available for troubleshooting, but they are
not the intended primary workflow.

## Complete package baseline

[`config/dusky-full.packages`](config/dusky-full.packages) contains the complete
validated router baseline. It is not limited to top-level LuCI applications.
Every package listed there must survive `make defconfig`, or the build fails.

### LuCI and management

- `luci`
- `luci-ssl`
- `luci-theme-bootstrap` until Footstrap replaces it
- `luci-app-firewall`

### SQM and CAKE

- `luci-app-sqm`
- `kmod-sched-core`
- `kmod-sched-cake`
- `kmod-ifb`
- `tc-tiny`
- `sqm-scripts`

### DNS proxy

- `dnsproxy`
- `ca-bundle`
- `ca-certificates`

The intended restored resolver path is dnsmasq forwarding to the local
`dnsproxy` service at `127.0.0.1#5453`. The separate `nextdns` daemon is not
installed because two competing local resolver paths would create ambiguous
DNS behavior.

### USB controller and storage

- `kmod-usb-core`
- `kmod-usb2`
- `kmod-usb3`
- `kmod-usb-dwc3`
- `kmod-usb-dwc3-qcom`
- `kmod-usb-xhci-hcd`
- `kmod-scsi-core`
- `kmod-usb-storage`
- `kmod-usb-storage-uas`
- `block-mount`
- `blockd`
- `usbutils`

`kmod-usb-dwc3-of-simple` is deliberately excluded. The flattened IPQ5332
controller binds through the Qualcomm DWC3 driver.

The old package name `kmod-phy-qcom-uniphy-usb` does not exist in this source
tree. IPQ5332 uses the built-in Qualcomm M31 USB PHY driver:

```text
CONFIG_PHY_QCOM_M31_USB=y
```

The build verifies that kernel setting directly.

### Filesystems

- `kmod-fs-ext4`
- `kmod-fs-exfat`
- `kmod-fs-ntfs3`
- `kmod-fs-vfat`
- `kmod-nls-base`
- `kmod-nls-cp437`
- `kmod-nls-iso8859-1`
- `kmod-nls-utf8`
- `e2fsprogs`
- `lsblk`

### SMB/NAS

- `kmod-fs-ksmbd`
- `ksmbd-server`
- `luci-app-ksmbd`
- `wsdd2`
- `umdns`

The firmware uses **ksmbd**, matching the known-good router configuration.
Samba 4 is deliberately excluded so two SMB servers cannot compete for port
445 or maintain separate share databases.

The restored NAS configuration is expected to mount the existing EXT4
partition persistently by UUID at:

```text
/mnt/nas
```

The firmware contains the required drivers and services. The disk UUID, ksmbd
users, passwords, share definitions and permissions are configuration data and
must come from the router backup or a device-specific restore process; they are
not hardcoded into a public firmware image.

### ZRAM

- `kmod-zram`
- `kmod-lib-lzo`
- `zram-swap`

### VPN, routing and WAN

- `luci-proto-wireguard`
- `luci-app-pbr`
- `luci-app-mwan3`

Additional OpenVPN, Tailscale, ZeroTier, travel/repeater, monitoring and media
features will be added only after their package identities and GUI workflows
are tested against this baseline.

## Flint 3 USB correction

Hardware testing of the first Dusky factory image showed:

- DWC3 bound successfully;
- USB 2.0 and USB 3.0 xHCI root hubs existed;
- storage and UAS drivers loaded;
- inserting a known-good drive produced no event;
- the drive received no VBUS power.

The board DTS already defined GPIO 16 as an output-high USB power enable, but
the USB controller did not select that pinctrl state. The Dusky patch now adds:

```dts
&usb {
	pinctrl-0 = <&usb_pins>;
	pinctrl-names = "default";
	qcom,multiplexed-phy;
	status = "okay";
};
```

The build verifies the GPIO 16 pinctrl state, the USB/PCIe PHY-mux property and
the built-in M31 USB PHY before compilation.

## Footstrap

**Footstrap** is the planned default LuCI theme and product interface. It is
expected to provide:

- a responsive desktop and mobile layout;
- a unified status dashboard;
- guided first-boot setup;
- simplified SQM, VPN, DNS, storage and multi-WAN workflows;
- cross-feature compatibility warnings;
- links to full native LuCI pages for advanced configuration.

Footstrap is not yet included. The current branch establishes the hardware,
package, validation and build foundation it will manage.

## Compatibility rules

The firmware must prevent or clearly warn about unsafe combinations including:

- SQM with hardware flow offloading;
- multiple DNS services owning the client resolver path;
- `dnsproxy` together with the separate `nextdns` daemon;
- ksmbd together with Samba 4;
- MLO SSIDs using 802.11r;
- guest networks gaining NAS access by default;
- VPN kill switches that do not cover IPv6 and DNS;
- multi-WAN failover bypassing a required VPN;
- SQM attached to the wrong interface after WAN-mode changes;
- network changes that can remove management access without rollback.

## Building

GitHub Actions is the preferred build environment. Development changes are
tested through draft pull requests; only `main` may publish firmware
prereleases.

A local build can be started with:

```bash
bash scripts/build.sh
```

The build process:

1. fetches the exact pinned Perceival commit;
2. applies the tracked Flint 3 USB patches;
3. validates the IPQ5332 USB PHY and VBUS pinctrl wiring;
4. installs OpenWrt feeds;
5. copies `config.seed` into the source tree;
6. applies the complete package baseline;
7. runs `make defconfig`;
8. validates every requested package;
9. rejects the generic DWC3 driver, Samba 4 and the separate NextDNS daemon;
10. downloads and compiles the firmware;
11. verifies the required factory and sysupgrade images;
12. exports firmware, checksums, the requested package list and resolved build
    configuration.

Successful builds create files under `release/`, including:

- `flint3-full-factory.bin`
- `flint3-sysupgrade.bin`
- `SHA256SUMS`
- `dusky-full.packages`
- `flint3-full.config`
- `flint3-full.diffconfig`

## Safety

This remains development firmware for hardware whose OpenWrt support is still
evolving. Before flashing:

- back up the eMMC and radio calibration data;
- retain a known-good recovery image;
- verify the image checksum and associated source commit;
- use the factory image only when transitioning from stock firmware;
- use the sysupgrade image for an existing OpenWrt installation;
- do not treat successful compilation as proof of hardware safety.

No stable release should be declared until Ethernet, all Wi-Fi radios, MLO,
USB storage, `/mnt/nas`, ksmbd, SQM, firewalling, DNS proxying, VPN routing,
upgrade and recovery have passed device testing.

## Repository history

The state before the Perceival-only source reset is preserved on:

```text
backup/pre-perceival-reset-2026-08-01
```

## Attribution

Flint 3 hardware enablement is based on Perceival's `openwrt-flint3` work and
the upstream OpenWrt ecosystem. This independent project is not affiliated
with or endorsed by GL.iNet or the OpenWrt project.

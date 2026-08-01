# Flint 3 OpenWrt Firmware

Public OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

## Source policy

This repository builds one pinned source tree only:

- `perceival/openwrt-flint3`, branch `flint3-be9300`

There is no Kakatkar branch overlay, patch-source import, file replacement, three-way source merge, or fallback integration in the active builder.

Changes developed by Kakatkar or any other contributor must first be submitted to and accepted by Perceival. Once they exist in the pinned Perceival tree, this builder can consume them normally on a later source update.

The only source modifications applied directly by this repository are reviewed local patches for:

- Migrating IPQ5332 to the flat `dwc3-qcom` binding.
- Selecting the verified USB PHY mux before the DWC3 reset sequence.
- Enabling the mux on the GL-BE9300 board.
- Retaining the Flint 3 ramoops crash-record reservation.

## Controlled builds

The firmware workflow is currently **manual-only**. Repository pushes do not start a firmware compilation, and a later run does not cancel a build already in progress.

A controlled build:

1. Checks out the exact Perceival commit pinned in `build.env`.
2. Applies only the curated USB/DWC3 and ramoops patches.
3. Uses pinned package, LuCI and Footstrap revisions.
4. Runs kernel-header, target patch-stack, kernel, ath12k, RTL837x and hostapd preflights before the complete image build.
5. Publishes only after the full build and image validation succeed.

Automatic nightly scheduling remains disabled until a complete build and hardware test succeed.

## Release assets

Every GitHub Release contains exactly two files:

- `flint3-full-factory.bin` — full stock-to-OpenWrt installation image.
- `flint3-sysupgrade.bin` — upgrade image for a router already running this OpenWrt port.

Build manifests and validation records remain in the Actions artifact and release notes rather than becoming extra Release assets.

## Included packages and defaults

The image includes:

- LuCI over HTTPS, with Footstrap selected by default and Bootstrap retained as a fallback.
- `kmod-ramoops` with early-boot pstore preservation under `/root/crashlogs`.
- `kmod-zram` and OpenWrt's standard compressed-RAM swap service.
- nftables flow-offload and conntrack support supplied by the selected Perceival source.
- SQM, CAKE and the LuCI SQM interface, installed but disabled by default.
- `ethtool`, `iperf3`, `tcpdump`, `iw-full`, `conntrack`, `curl`, `jq`, `lsblk` and `usbutils`.
- USB 2/3, xHCI, DWC3, mass-storage, UAS, ext4, exFAT, NTFS3 and VFAT support.

The image does not create disk-backed swap, mount disks, create shares or embed router-specific network configuration.

When enabling SQM, disable software and hardware flow offloading so shaped traffic passes through CAKE.

## Wireless first setup

No country, SSID, password or radio-specific user configuration is embedded.

Select the correct regulatory country in LuCI or run:

```sh
flint3-set-country <CC>
```

The helper only sets the two-letter regulatory country. It does not create an SSID, set a password, enable a radio or select a network.

## Privacy boundary

The public firmware does not include:

- Personal SSIDs, passwords, BSSIDs or client MAC addresses.
- Static leases, private addressing or client allowlists.
- Account-specific DNS endpoints.
- Personal firewall rules, forwards or UPnP permissions.
- Storage paths, disk labels, NAS configuration or personal hostnames.

A build-time privacy audit rejects common forms of live-router data.

## Local CachyOS build

Run as your normal desktop user, not as root:

```bash
curl -fsSL https://raw.githubusercontent.com/DuskyProjects/flint3-openwrt/main/scripts/build-local-cachyos.sh | bash
```

The script installs the required CachyOS/Arch packages, downloads the current builder, validates it, and builds the pinned Perceival source with the curated USB/ramoops patches. It does not flash or reboot the router.

Output is written to:

```text
/mnt/router/flint3-local-build/
```

Expected files:

- `flint3-full-factory.bin`
- `flint3-sysupgrade.bin`
- `release-notes.md`
- `sha256sums.txt`
- `build.log`

The build needs at least 30 GiB of free local space under `~/.cache/flint3-openwrt-local`. Existing download and compiler caches are reused.

## Manual GitHub build

Open **Actions**, select **Build Perceival Flint 3 firmware**, and choose **Run workflow**.

## Flashing warning

Back up the router's eMMC and ART data before flashing. ART contains unit-specific Wi-Fi calibration and MAC-address information.

Use `flint3-full-factory.bin` only for the documented stock-to-OpenWrt installation path. Use `flint3-sysupgrade.bin` for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

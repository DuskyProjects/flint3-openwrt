# Flint 3 OpenWrt Firmware

Public OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

The project combines the newest usable Flint 3 work from the listed source trees with the reusable package set, diagnostics, recovery tools and performance defaults established during router testing. It deliberately excludes the configuration of any individual router.

## Controlled releases

The firmware workflow is currently **manual-only** while the integrated source is being validated. Repository pushes do not start a firmware compilation, and a later run does not cancel an existing run.

Each controlled build:

1. Reads recent revisions from `perceival/openwrt-flint3` branch `flint3-be9300`.
2. Requires the current `KakatkarAkshay/openwrt` branch `gl-be9300` as one coherent Flint networking source.
3. Three-way integrates reviewed Flint-specific source files instead of merging entire OpenWrt trees.
4. Imports the required Kakatkar Qualcomm PPE/EDMA, RTL837x and ath12k patch series, with optional reviewed patch sources tried separately.
5. Applies curated local patches, including the IPQ5332 migration to the flat `dwc3-qcom` binding and the early USB/PCIe PHY-mux selection.
6. Tests current feeds first and then the pinned known-good feed set without dropping the required Kakatkar series.
7. Publishes only a candidate that passes validation and compilation.

Automatic nightly scheduling will remain disabled until a complete build and hardware test have succeeded.

## Release assets

Every GitHub Release contains exactly two assets:

- `flint3-full-factory.bin` — full stock-to-OpenWrt installation image.
- `flint3-sysupgrade.bin` — upgrade image for a router already running this OpenWrt port.

Build manifests, source selections and validation records are included in the Actions artifact and release notes rather than attached as extra Release assets.

Development releases are marked as prereleases because compilation and integration checks do not replace long-term hardware soak testing.

## Hardware and source fixes

The integrated source includes compatible Flint 3 work from the selected trees, including:

- IPQ5332 and QCN9274 ath12k Wi-Fi 7 support and mixed-bus MLO.
- MLO transmit-link handling when link zero is absent or the link is unspecified.
- Multi-AP operation after DFS CAC.
- RTL8372N DSA switching, FDB/MDB handling and Qualcomm PPE/EDMA support.
- PPE flow offloading through DSA and Wi-Fi virtual-port paths.
- Correct PPE L3 row writes, per-flow path MTU programming and stale-flow teardown.
- Preservation of DSA identity tags on CPU-punted PPE traffic.
- Correct checksum handling, CPU tagging, SerDes lane swaps and physical port labels.
- Factory Ethernet and Wi-Fi MAC derivation from each router's own ART data.
- Fan, thermal-zone, USB controller/PHY and ramoops support.
- Late-radio recovery and WDS/AP-VLAN fixes.
- QSDK-compatible factory image creation and stock-firmware restoration support.
- Flat IPQ5332 `dwc3-qcom` integration with explicit USB mux selection before controller reset.

`source.required` lists critical baseline commits which must remain present. Reviewed local patches under `patches/` are applied when absent, accepted when already identical upstream, and rejected on incompatible conflicts rather than being silently discarded.

## Additional packages and defaults

### Interface, memory and recovery

- LuCI over HTTPS.
- Footstrap selected by default.
- Bootstrap retained as a fallback.
- `kmod-ramoops` and early-boot pstore preservation under `/root/crashlogs`.
- `kmod-zram` and OpenWrt's standard compressed-RAM swap service.
- A larger in-memory log ring without continuous eMMC logging.

The image does not create disk-backed swap.

### Performance and traffic management

- Qualcomm PPE/EDMA support from the integrated source.
- nftables flow offloading and conntrack support.
- Software and hardware flow offloading enabled by default.
- Standard all-CPU packet steering.
- SQM, CAKE and the LuCI SQM interface installed but disabled by default.
- Experimental local-flow steering and interrupt-balancing changes excluded.

When enabling SQM, disable software and hardware flow offloading so traffic passes through the shaper.

### Diagnostics

- `ethtool`
- `iperf3`
- `tcpdump`
- `iw-full`
- `conntrack`
- `curl` and CA certificates
- `jq`
- `lsblk`
- `usbutils`

### Generic USB and removable storage

- USB core, USB 2/3, xHCI, DWC3 and Qualcomm DWC3 glue modules.
- SCSI, USB mass-storage and UAS modules.
- ext4, exFAT, NTFS3 and VFAT modules.
- `block-mount`, `blockd`, `e2fsprogs`, `lsblk` and `usbutils`.

The image does not create mounts, choose disks, create shares or start file-sharing services.

## Wireless first setup

No country, SSID, password or radio-specific user configuration is embedded.

A regulatory country must be selected before 6 GHz can start. Set the correct country in LuCI or run:

```sh
flint3-set-country <CC>
```

The helper only sets the two-letter regulatory country. It does not create an SSID, set a password, enable a radio or select a network.

## Privacy boundary

The build contains no copied `/etc/config/wireless`, `network`, `dhcp`, `firewall`, `fstab`, `samba4` or `upnpd` file. A build-time privacy audit rejects common forms of live-router data.

The public firmware does not include:

- Personal SSIDs, passwords, BSSIDs or client MAC addresses.
- Static leases, private addressing or client allowlists.
- Account-specific DNS endpoints.
- Personal firewall rules, forwards or UPnP permissions.
- Storage paths, disk labels, disk-backed swap or NAS configuration.
- Personal hostnames or local search domains.

## Deliberately excluded vendor modules

Older vendor firmware used proprietary Linux 5.4 QCA NSS/ECM and iptables full-cone modules. Those binary and kernel-specific modules are not portable to this mainline development tree and are not replaced with unreviewed third-party code.

The supported paths used here are Qualcomm PPE/EDMA, nftables flow offloading, standard conntrack and CAKE/SQM.

## Local CachyOS build

Run as your normal desktop user, not as root:

```bash
curl -fsSL https://raw.githubusercontent.com/DuskyProjects/flint3-openwrt/main/scripts/build-local-cachyos.sh | bash
```

The script installs the required CachyOS/Arch packages, downloads the current builder, runs syntax/privacy/integration self-tests, and then performs the controlled firmware build. It does not flash or reboot the router.

The default output directory is:

```text
/mnt/router/flint3-local-build/
```

It contains:

- `flint3-full-factory.bin`
- `flint3-sysupgrade.bin`
- `release-notes.md`
- `sha256sums.txt`
- `build.log`

The build needs at least 30 GiB of free local space under `~/.cache/flint3-openwrt-local`. Override `STATE_ROOT`, `EXPORT_DIR`, `JOBS` or `MIN_FREE_GIB` in the environment when necessary.

## Manual GitHub build

Open **Actions**, select **Build integrated Flint 3 firmware**, and choose **Run workflow**. The workflow runs the same self-tests before beginning the expensive OpenWrt compilation.

## Flashing warning

Back up the router's eMMC/ART data before flashing. ART contains unit-specific Wi-Fi calibration and MAC-address information.

Use `flint3-full-factory.bin` only for the documented stock-to-OpenWrt installation path. Use `flint3-sysupgrade.bin` for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

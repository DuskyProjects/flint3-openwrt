# Flint 3 OpenWrt Firmware

Public merged-nightly OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

The project combines the newest usable Flint 3 work from the listed source trees with the reusable package set, diagnostics, recovery tools and performance defaults established during router testing. It deliberately excludes the configuration of any individual router.

## Nightly releases

GitHub Actions runs every night and also supports manual runs.

Each run:

1. Reads recent revisions from `perceival/openwrt-flint3` branch `flint3-be9300`.
2. Reads recent revisions from `KakatkarAkshay/openwrt` branch `gl-be9300`.
3. Tries the newest source pair first and merges both histories without automatic conflict resolution.
4. Uses the newest OpenWrt packages feed, LuCI feed and Footstrap revision first.
5. If that combination does not merge, validate or compile, progressively tries recent source revisions and the known-good pinned feed set.
6. Publishes the first and therefore newest tested combination that passes all checks and compiles.

A nightly run only fails without a release when none of the tested recent combinations works.

## Release assets

Every nightly GitHub Release contains exactly two assets:

- `flint3-full-factory.bin` — full stock-to-OpenWrt installation image.
- `flint3-sysupgrade.bin` — upgrade image for a router already running this OpenWrt port.

Build manifests, logs, source selections and validation records remain in the Actions run and release notes. They are not attached as additional release assets.

Nightly releases are marked as prereleases because they follow moving development branches and have passed compilation checks rather than long-term hardware soak testing.

## Hardware and source fixes

The merged source includes the compatible fixes available from both Flint 3 development trees, including:

- IPQ5332 and QCN9274 ath12k Wi-Fi 7 support and mixed-bus MLO.
- MLO transmit-link handling when link zero is absent.
- Multi-AP operation after DFS CAC.
- RTL8372N DSA switching and Qualcomm PPE/EDMA support.
- PPE flow offloading improvements from the selected source revision.
- Correct checksum handling, CPU tagging, SerDes lane swaps and physical port labels.
- Factory Ethernet and Wi-Fi MAC derivation from each router's own ART data.
- Fan, thermal-zone, USB controller/PHY and ramoops support.
- Late-radio recovery and WDS/AP-VLAN fixes.
- QSDK-compatible factory image creation and stock-firmware restoration support.

`source.required` lists critical baseline commits which must remain present in the merged tree. Reviewed local patches under `patches/` are applied when absent, accepted when already identical upstream, and rejected when an upstream file conflicts rather than being silently overwritten.

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

- Qualcomm PPE/EDMA support from the merged source.
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

## Manual build

Open **Actions**, select **Build merged Flint 3 nightly**, and choose **Run workflow**. The same candidate-selection and release rules used by the scheduled nightly run apply.

## Flashing warning

Back up the router's eMMC/ART data before flashing. ART contains unit-specific Wi-Fi calibration and MAC-address information.

Use `flint3-full-factory.bin` only for the documented stock-to-OpenWrt installation path. Use `flint3-sysupgrade.bin` for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

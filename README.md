# Flint 3 OpenWrt Firmware

Reproducible public OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

The project keeps the reusable hardware fixes, kernel modules, diagnostics and performance defaults established during Flint 3 testing. It deliberately does **not** copy the configuration of any individual router.

## Firmware outputs

Every successful GitHub Actions run produces:

- `*factory.bin` — full stock-to-OpenWrt installation image.
- `*sysupgrade.bin` — upgrade image for a router already running this OpenWrt port.
- Image SHA-256 hashes.
- The final expanded OpenWrt configuration and exact image package manifest.
- A factory-FIT listing proving that `hlos` and `rootfs` are present.
- Pinned OpenWrt, package-feed, LuCI-feed and Footstrap revisions.
- Required-package, required-source-fix and custom-patch verification records.
- The privacy-audit result.

## Hardware and source fixes

The pinned `perceival/openwrt-flint3` tree supplies the board-specific work, including:

- IPQ5332 and QCN9274 ath12k Wi-Fi 7 support and mixed-bus MLO.
- RTL8372N DSA switching and Qualcomm PPE Ethernet support.
- Correct checksum handling, CPU tagging, SerDes lane swaps and physical port labels.
- Factory Ethernet and Wi-Fi MAC derivation from each unit's own ART data.
- Fan, thermal-zone, USB controller/PHY and ramoops support.
- Late-radio setup recovery, WDS/AP-VLAN fixes and multi-AP DFS-CAC handling.
- QSDK-compatible `factory.bin` creation and the tested path back to stock firmware.

`source.required` lists the critical source commits. The build stops if a future source pin drops any of them.

The builder also carries the signed ath12k fix that selects a valid active MLO link when link zero is absent. The pinned Perceival tree does not contain that patch, so it is applied explicitly from `patches/mac80211-ath12k/` and its SHA-256 is recorded with the build artifacts.

## Additional packages and defaults

### Interface, memory and recovery

- LuCI over HTTPS.
- Footstrap installed and selected by default.
- Bootstrap retained as a fallback.
- `kmod-ramoops` and an early-boot service that saves surviving pstore records under `/root/crashlogs`.
- `kmod-zram` and OpenWrt's standard `zram-swap` service for compressed RAM swap.
- A larger in-memory log ring without continuous eMMC logging.

The image does not create disk-backed swap. Zram sizing and service policy remain normal OpenWrt configuration, so firmware upgrades do not erase a user's later choices.

### Performance and traffic management

- Qualcomm PPE/EDMA support from the board port.
- nftables flow offloading, standard conntrack and conntrack-netlink support.
- Software and hardware flow offloading enabled on first boot.
- Standard all-CPU packet steering enabled.
- SQM, CAKE and the LuCI SQM interface installed but disabled by default.
- Experimental local-flow steering and interrupt-balancing changes are not included.

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

### Generic USB and removable-storage support

- USB core, USB 2/3, xHCI, DWC3 and Qualcomm DWC3 glue modules.
- SCSI, USB mass-storage and UAS modules.
- ext4, exFAT, NTFS3 and VFAT modules.
- `block-mount`, `blockd`, `e2fsprogs`, `lsblk` and `usbutils`.

These packages provide generic hardware and filesystem support only. The image does not create a mount, select a disk, share a directory, start a file-sharing service or assume that storage exists.

## Wireless first setup

No country, SSID, encryption key or radio-specific user configuration is embedded.

A regulatory country must be selected before 6 GHz can start. Set the correct country in LuCI or run:

```sh
flint3-set-country <CC>
```

Replace `<CC>` with the correct two-letter ISO country code. The helper only sets the country; it does not create an SSID, set a password, enable a radio or choose a network.

## Privacy and mass-adoption boundary

The build contains no copied `/etc/config/wireless`, `network`, `dhcp`, `firewall`, `fstab`, `samba4` or `upnpd` file. A build-time audit rejects common forms of live-router data before compilation.

The public firmware does **not** include:

- Personal SSIDs, Wi-Fi passwords, BSSIDs or client MAC addresses.
- Static leases, client allowlists or hard-coded private addresses.
- Account-specific encrypted-DNS endpoints.
- Personal firewall/NFT rules, port forwards or UPnP permissions.
- Storage mount paths, disk labels, disk-backed swap, file-sharing, discovery or media-server configuration.
- Hostnames or local search domains copied from a live network.

## Deliberately not copied from older vendor firmware

Older vendor firmware used Linux 5.4 proprietary GL.iNet/Qualcomm packages such as QCA NSS/ECM acceleration and an iptables full-cone NAT module. Those binary and kernel-specific modules are not portable to this mainline kernel-6.18 tree and are not silently replaced with unreviewed third-party code.

The supported mainline paths used here are Qualcomm PPE/EDMA, nftables flow offloading, standard conntrack and CAKE/SQM.

## Build firmware

1. Open **Actions** in this repository.
2. Select **Build Flint 3 firmware**.
3. Select **Run workflow**.
4. Download the `flint3-openwrt-footstrap` artifact after the build succeeds.

The workflow stops if:

- A critical Flint 3 source commit is absent.
- A custom patch would overwrite an upstream patch or fails during compilation.
- A required package is dropped by `make defconfig` or absent from the final image manifest.
- The factory image lacks `hlos` or `rootfs`.
- A zero-byte source archive is downloaded.
- Live network or storage configuration is detected in the image overlay.

## Flashing warning

Back up the router's eMMC/ART data before flashing. ART contains unit-specific Wi-Fi calibration and MAC-address information.

Use the **factory** image only for the documented stock-to-OpenWrt installation path. Use the **sysupgrade** image for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

## Reproducibility

All source revisions are pinned in `build.env`. Updating a pin creates a reviewable firmware change instead of silently rebuilding against a moving target.

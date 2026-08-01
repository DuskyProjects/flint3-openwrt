# Flint 3 OpenWrt Firmware

Reproducible public OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

The project keeps reusable hardware fixes, packages, diagnostics and performance defaults established during Flint 3 testing. It deliberately does **not** copy the configuration of any individual router.

## Firmware outputs

Every successful GitHub Actions run produces:

- `*factory.bin` — full stock-to-OpenWrt installation image.
- `*sysupgrade.bin` — upgrade image for a router already running this OpenWrt port.
- Image SHA-256 hashes.
- The final expanded OpenWrt configuration and diffconfig.
- The exact image package manifest.
- A factory-FIT listing proving that `hlos` and `rootfs` payloads are present.
- Pinned OpenWrt, package-feed, LuCI-feed and Footstrap source revisions.
- The required-package list and privacy-audit result.

## Hardware and upstream port features

The pinned `perceival/openwrt-flint3` tree supplies the board-specific work, including:

- IPQ5332 and QCN9274 ath12k Wi-Fi 7 support.
- Multi-Link Operation support across the Flint 3 radios.
- RTL8372N DSA switch and Qualcomm PPE Ethernet support.
- Factory Ethernet and Wi-Fi MAC derivation from each unit's own ART data.
- Fan and thermal-zone support.
- Late-radio setup recovery, WDS/AP-VLAN fixes, MLO transmit-link handling and multi-AP DFS-CAC handling.
- QSDK-compatible `factory.bin` creation and the tested path back to stock firmware.
- A reserved ramoops region for persistent crash records.

## Additional packages in this image

### Interface and recovery

- LuCI over HTTPS.
- Footstrap installed and selected by default.
- Bootstrap retained as a fallback theme.
- `kmod-ramoops` plus a small service that copies surviving pstore records to `/root/crashlogs` after a warm reboot.

### Performance and traffic management

- `kmod-nft-offload`.
- Software and hardware flow offloading enabled on first boot.
- Standard all-CPU packet steering enabled.
- Experimental local-flow steering and interrupt-balancing changes are not included.
- SQM, CAKE and the LuCI SQM interface are installed but not enabled automatically.

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

### Generic removable-storage support

- USB 3, USB mass-storage and UAS kernel modules.
- ext4, exFAT and NTFS3 filesystem modules.
- `block-mount` and `e2fsprogs`.

These packages only make common removable media usable. The image does not create a mount, share a directory, start a file-sharing service or assume that a disk exists.

## Wireless first setup

No country, SSID, encryption key or radio-specific user configuration is embedded.

A regulatory country must be selected before 6 GHz can start. Set the correct country in LuCI or use:

```sh
flint3-set-country <CC>
```

Replace `<CC>` with the correct two-letter ISO country code. The helper only sets the country; it does not create an SSID, set a password, enable a radio or choose a network.

## Privacy and mass-adoption boundary

The build contains no copied `/etc/config/wireless`, `network`, `dhcp`, `firewall`, `fstab`, `samba4` or `upnpd` file. A build-time privacy audit rejects common forms of live-router data before compilation.

The public firmware does **not** include:

- Personal SSIDs or Wi-Fi passwords.
- Hard-coded Wi-Fi BSSIDs or client MAC addresses.
- Static leases, client allowlists or private LAN addresses.
- Account-specific encrypted-DNS endpoints.
- Personal firewall/NFT rules or port forwards.
- Storage mount paths, disk labels, file-sharing configuration, discovery services or media-server configuration.
- UPnP permissions tied to a particular device.
- Hostnames or local search domains copied from a live network.

## Deliberately not copied from older vendor firmware

Older vendor firmware used Linux 5.4 proprietary GL.iNet/Qualcomm packages such as QCA NSS/ECM acceleration and an iptables full-cone NAT module. Those binary and kernel-specific modules are not portable to this mainline kernel-6.18 OpenWrt tree and are not silently replaced with unreviewed third-party code.

The supported mainline paths used here are Qualcomm PPE Ethernet support from the Flint 3 port, nftables flow offloading, standard conntrack and CAKE/SQM.

## Build firmware

1. Open **Actions** in this repository.
2. Select **Build Flint 3 firmware**.
3. Select **Run workflow**.
4. Download the `flint3-openwrt-footstrap` artifact after the build succeeds.

The workflow fails if:

- A required package is dropped by `make defconfig`.
- A required package is absent from the final image manifest.
- The factory image lacks `hlos` or `rootfs`.
- A zero-byte source archive is downloaded.
- Live network or storage configuration is detected in the image overlay.

## Flashing warning

Back up the router's eMMC/ART data before flashing. ART contains unit-specific Wi-Fi calibration and MAC-address information.

Use the **factory** image only for the documented stock-to-OpenWrt installation path. Use the **sysupgrade** image for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

## Source pins

Source revisions are pinned in `build.env`. Updating a pin creates a reproducible and reviewable firmware change instead of silently rebuilding against an unknown moving target.

# Flint 3 OpenWrt Firmware

Custom OpenWrt firmware builder for the **GL.iNet Flint 3 / GL-BE9300**.

## Included changes

- Based on `perceival/openwrt-flint3`, branch `flint3-be9300`.
- Builds both the full `factory.bin` and normal `sysupgrade.bin` images.
- Includes LuCI.
- Includes [luci-theme-footstrap](https://github.com/VizzleTF/luci-theme-footstrap).
- Makes Footstrap the active/default LuCI theme on first boot.
- Keeps Bootstrap installed as a fallback theme.
- Includes `kmod-ramoops` so the reserved pstore/ramoops crash-log region can work.
- Uploads images, hashes, package manifests, and the final build configuration as a GitHub Actions artifact.

## Build firmware

1. Open **Actions** in this repository.
2. Select **Build Flint 3 firmware**.
3. Select **Run workflow**.
4. Download the `flint3-openwrt-footstrap` artifact after the build succeeds.

The artifact contains:

- `*factory.bin` — full installation image used when moving from stock firmware.
- `*sysupgrade.bin` — upgrade image used when OpenWrt is already installed.
- `IMAGE-SHA256SUMS` — hashes for the two images.
- `sha256sums` and `profiles.json` from the OpenWrt build.
- `build.config` — exact final OpenWrt configuration.
- `SOURCES.txt` — pinned source revisions.

## Flashing warning

Back up the router's eMMC/ART data before flashing. The ART partition contains unit-specific Wi-Fi calibration and MAC-address information.

Use the **factory** image only for the documented stock-to-OpenWrt installation path. Use the **sysupgrade** image for upgrades from OpenWrt. Do not force an image intended for the wrong installation path.

## Source pins

The source revisions are intentionally pinned in `build.env`. Updating a pin creates a reproducible, reviewable firmware change instead of silently rebuilding against an unknown moving target.

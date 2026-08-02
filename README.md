# Flint 3 OpenWrt builder

Minimal firmware builder for the GL.iNet Flint 3 (GL-BE9300).

## Source policy

The OpenWrt source tree is pinned to `perceival/openwrt-flint3`,
branch `flint3-be9300`. No second OpenWrt tree, source overlay, or external
patch feed is used.

This repository adds only:

- the Flint 3 package configuration, including `iperf3`;
- the IPQ5332 USB PHY-mux fixes under `patches/`;
- a small helper that creates the unpublished backports 7.2-rc4 source archive;
- one build script and one GitHub Actions workflow.

## Build

Run the **Build Percival Flint 3 firmware** workflow from the Actions tab, or:

```bash
bash scripts/build.sh
```

Successful builds create:

- `release/flint3-full-factory.bin`
- `release/flint3-sysupgrade.bin`

The pre-reset repository is preserved on
`backup/pre-perceival-reset-2026-08-01`.

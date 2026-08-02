# Reproducible Percival Flint 3 builder

This repository builds standard router firmware for the GL.iNet Flint 3
(GL-BE9300) from `perceival/openwrt-flint3` only.

It replaces floating-HEAD automation with explicit source resolution:

- scheduled builds select the newest `tested-*` tag;
- manual builds accept `latest-tested`, an exact tag, a full commit SHA, or a
  branch name;
- CI builds on automation branches use the full commit pinned in `source.lock`;
- every build checks out the resolved commit in detached-HEAD state and records
  the exact source metadata in its artifacts.

## Source and configuration policy

- Upstream repository: `perceival/openwrt-flint3`
- Expected upstream branch: `flint3-be9300`
- Target: `qualcommbe/ipq53xx`
- Device: `glinet_gl-be9300`
- External OpenWrt trees, source overlays, generated backports archives, and
  builder-supplied source patches are not used.
- Custom Dusky firmware changes are maintained separately and are not part of
  this workflow.

The package seed in `configs/router.seed` keeps the standard router profile and
adds only LuCI HTTPS, `iperf3`, `ethtool`, `tcpdump`, `kmod-ramoops`, an
initramfs recovery image, and build provenance options.

Percival's `configs/ap.config` is intentionally not used: it is a dumb-AP
configuration without the normal router firewall, DHCP, DNS, and PPPoE stack.

## Workflows

### Validate Percival builder

Runs YAML validation, `actionlint`, `shellcheck`, Bash syntax checks, source
policy checks, and configuration assertions. It does not compile OpenWrt.

### Build pinned Percival Flint 3 firmware

Runs in three modes:

1. Every six hours on the default branch, it checks for the newest Percival
   `tested-*` tag. If the matching prerelease already exists, it exits without
   rebuilding.
2. Manual dispatch accepts an exact source selection. Publishing is allowed
   only when that selection resolves to a `tested-*` tag.
3. Pushes to `agent/**` branches build the exact `CI_SOURCE_COMMIT` from
   `source.lock` without publishing a release.

## Build outputs

Successful runs retain the original OpenWrt firmware filenames and upload:

- the GL-BE9300 factory image;
- the GL-BE9300 sysupgrade image;
- any GL-BE9300 initramfs image produced by OpenWrt;
- `SHA256SUMS`;
- `BUILD-MANIFEST.txt` and `SOURCE-COMMIT.txt`;
- the expanded diffconfig and feed commit lock;
- the package manifest, factory FIT inspection, file-type report, upstream
  known issues, and compressed build log.

The build fails if it finds zero-byte downloads, HTML error pages in the source
cache, missing or duplicate factory/sysupgrade images, an unparseable factory
FIT, or a source-tree modification.

## Local use

The scripts require network access and the normal OpenWrt build dependencies.
From the repository root:

```bash
bash scripts/resolve-source.sh latest-tested
bash scripts/build-percival.sh
```

To reproduce a specific source revision, replace `latest-tested` with an exact
tag or full 40-character commit SHA.

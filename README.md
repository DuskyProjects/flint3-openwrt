# Percival Flint 3 automation

This repository contains two strictly separated automation tracks for the
GL.iNet Flint 3 (GL-BE9300). Both use only
`perceival/openwrt-flint3`; neither applies builder-supplied source patches,
source overlays, generated backports archives, or a second OpenWrt tree.

Custom Dusky firmware is maintained separately in the Dusky custom-build track
and is not part of these workflows.

## Source policy

- Upstream repository: `perceival/openwrt-flint3`
- Upstream development branch: `flint3-be9300`
- Target: `qualcommbe/ipq53xx`
- Device: `glinet_gl-be9300`
- Every checkout is detached at an exact 40-character source commit.
- Every artifact records the source ref, commit, date, title, configuration,
  feed commits, builder commit, and workflow run.

## Track 1: untested Percival HEAD

Workflow: `.github/workflows/percival-head.yml`

Track 1 polls the current `flint3-be9300` branch HEAD every six hours. The
branch is resolved to its exact commit before building.

The Track 1 package configuration is `configs/head-diagnostic.seed`. It carries
forward the original iperf3 bring-up profile:

- normal GL-BE9300 router target;
- LuCI with HTTPS;
- `iperf3`, `ethtool`, and `tcpdump`;
- `kmod-ramoops`;
- SquashFS and initramfs images.

Track 1 outputs are Actions artifacts named:

```text
UNTESTED-PERCIVAL-<12-character-source-commit>
```

Track 1 never creates or modifies a GitHub Release. If an unexpired artifact
already exists for the same source commit, a scheduled run exits without
rebuilding it.

## Track 2: tested Percival tags

Workflow: `.github/workflows/percival-tested.yml`

Track 2 polls the newest annotated `tested-*` tag every six hours, resolves the
tag to its exact commit, verifies that it is an annotated tag, and preserves the
tag annotation verbatim.

Track 2 builds these variants:

1. **Router** — `configs/tested-router.seed` selects the GL-BE9300 target and
   retains Percival's normal device profile without adding packages.
2. **AP** — when the selected tested source contains `configs/ap.config`, the
   workflow builds that upstream sanitized dumb-AP configuration unchanged.

A tested tag created before `configs/ap.config` existed produces only the router
variant. Pull-request validation separately builds the current pinned AP source
so the AP path is tested before a later tagged release activates it.

Successful Track 2 builds are Actions artifacts named:

```text
TESTED-<upstream-tag>-router
TESTED-<upstream-tag>-ap
```

Scheduled Track 2 runs publish a prerelease named `percival-<upstream-tag>`.
The GitHub Release body is the upstream annotated tag message verbatim. Firmware
assets retain the full OpenWrt filename and add only a final `-router` or `-ap`
variant suffix before the extension so both variants can coexist in one
release. The workflow also publishes a combined `SHA256SUMS`.

When a tag annotation contains a `Supersedes:` trailer, the corresponding older
builder release is retitled with a `[SUPERSEDED]` prefix after the replacement
release succeeds. Its original release body is left unchanged.

## Validation workflow

Workflow: `.github/workflows/validate.yml`

The validation workflow runs:

- YAML parsing;
- `actionlint`;
- Bash syntax checks;
- ShellCheck;
- source-policy assertions;
- checks that Track 1 cannot contain release commands;
- checks that Track 2 uses the upstream AP configuration and annotated tag body;
- checks that legacy and collapsed workflows remain absent.

## Build outputs

Each successful firmware variant contains:

- exactly one GL-BE9300 factory image;
- exactly one GL-BE9300 sysupgrade image;
- any GL-BE9300 initramfs image produced by OpenWrt;
- `SHA256SUMS`;
- `BUILD-MANIFEST.txt`;
- `SOURCE-COMMIT.txt`;
- `flint3-build.diffconfig`;
- `input.config`;
- `feeds-lock.txt`;
- `package-manifest.txt`;
- `factory-fit.txt`;
- `firmware-file-types.txt`;
- upstream known issues when present;
- compressed build logs.

The build fails on zero-byte downloads, HTML error pages stored as source
archives, missing or duplicate factory/sysupgrade images, an unparseable
factory FIT, missing `hlos` or `rootfs` FIT sections, checksum failures, source
commit mismatches, unexpected origin URLs, or tracked source modifications.

## Local validation

Resolve an exact source first, then select a build variant:

```bash
bash scripts/resolve-source.sh flint3-be9300
BUILD_VARIANT=head-diagnostic \
CONFIG_SOURCE="$PWD/configs/head-diagnostic.seed" \
RELEASE_DIR="$PWD/release/head-diagnostic" \
bash scripts/build-percival.sh
```

For a tested router build:

```bash
bash scripts/resolve-source.sh latest-tested
BUILD_VARIANT=tested-router \
CONFIG_SOURCE="$PWD/configs/tested-router.seed" \
RELEASE_DIR="$PWD/release/router" \
bash scripts/build-percival.sh
```

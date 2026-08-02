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

## Track 2: published Percival releases

Workflow: `.github/workflows/percival-tested.yml`

Track 2 does **not** build from tags alone. It queries Percival's GitHub
Releases and becomes eligible only when a published, non-draft `tested-*`
release actually exists. A `tested-*` Git tag without a corresponding GitHub
Release is ignored.

Because Percival has not published a qualifying GitHub Release yet, Track 2 is
currently expected to resolve successfully, report that no release exists, and
skip every firmware build and publication job.

When Percival publishes a qualifying release, Track 2 will resolve its release
tag to an exact commit and build two variants:

1. **Router** — `configs/tested-router.seed` selects the GL-BE9300 target and
   retains Percival's normal device profile without adding packages.
2. **AP** — the exact released source commit is built with Percival's sanitized
   dumb-AP package selection from the separately pinned `configs/ap.config`
   commit recorded in `source.lock`.

The AP configuration is pinned by both commit and Git blob ID. This supports a
released source snapshot that predates the checked-in `configs/ap.config` file
without using moving HEAD. AP artifacts record the released source commit, AP
configuration commit, configuration URL, and input SHA256 independently.

Successful Track 2 builds will be Actions artifacts named:

```text
RELEASED-<upstream-release-tag>-router
RELEASED-<upstream-release-tag>-ap
```

Scheduled Track 2 runs publish a builder prerelease named
`percival-<upstream-release-tag>`. Publication is blocked unless both variants
succeeded. The builder release body is copied from Percival's actual GitHub
Release body, not inferred from a tag. Firmware assets retain the full OpenWrt
filename and add only a final `-router` or `-ap` suffix before the extension so
both variants can coexist. The release also contains a combined `SHA256SUMS`,
the upstream release metadata, and per-variant provenance files.

When an upstream release body contains a `Supersedes:` trailer, the
corresponding older builder release is retitled with a `[SUPERSEDED]` prefix
after the replacement release succeeds. Its original release body is left
unchanged.

## Validation workflow

Workflow: `.github/workflows/validate.yml`

The validation workflow runs:

- YAML parsing;
- `actionlint`;
- Bash syntax checks;
- ShellCheck;
- source-policy assertions;
- checks that Track 1 cannot contain release commands;
- checks that Track 2 requires an actual upstream GitHub Release;
- checks that a tag-only snapshot cannot activate Track 2 builds;
- checks that future Track 2 releases contain router and AP variants;
- checks that the Percival AP configuration is pinned by commit and blob;
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
commit mismatches, unexpected origin URLs, AP configuration commit/blob
mismatches, or tracked source modifications.

## Local Track 1 validation

```bash
bash scripts/resolve-source.sh flint3-be9300
BUILD_VARIANT=head-diagnostic \
CONFIG_SOURCE="$PWD/configs/head-diagnostic.seed" \
RELEASE_DIR="$PWD/release/head-diagnostic" \
bash scripts/build-percival.sh
```

Track 2 should not be run locally against a bare tag. Its source must first be
verified as an actual Percival GitHub Release by the workflow.

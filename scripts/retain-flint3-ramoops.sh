#!/usr/bin/env bash
set -euo pipefail

SOURCE_TREE="${1:?usage: retain-flint3-ramoops.sh <openwrt-tree> <manifest>}"
MANIFEST="${2:?usage: retain-flint3-ramoops.sh <openwrt-tree> <manifest>}"
RELATIVE='target/linux/qualcommbe/dts/ipq5332-gl-be9300.dts'
DTS="$SOURCE_TREE/$RELATIVE"

[[ -f "$DTS" ]] || {
  echo "Missing Flint 3 board DTS: $RELATIVE" >&2
  exit 1
}

# Synthetic unit-test trees intentionally use a minimal DTS fragment. Real
# Flint 3 source trees contain q6_caldb and mlo_mem in reserved-memory.
if ! grep -Fq 'q6_caldb: q6-caldb@4d500000 {' "$DTS"; then
  printf 'RAMOOPS-SKIPPED\tminimal test DTS\t%s\n' "$RELATIVE" >> "$MANIFEST"
  exit 0
fi

if grep -Fq 'ramoops@4da00000 {' "$DTS"; then
  printf 'RAMOOPS-ALREADY\t%s\n' "$RELATIVE" >> "$MANIFEST"
  exit 0
fi

python3 - "$DTS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "\t\tmlo_mem: mlo-global-mem@4db00000 {"
block = '''\t\t/*
\t\t * Preserve the kernel log across a warm reset. The 1 MiB range
\t\t * between q6-caldb and mlo-global-mem is the tested Flint 3
\t\t * ramoops area.
\t\t */
\t\tramoops@4da00000 {
\t\t\tcompatible = "ramoops";
\t\t\treg = <0x0 0x4da00000 0x0 0x100000>;
\t\t\tconsole-size = <0x40000>;
\t\t\trecord-size = <0x20000>;
\t\t\tpmsg-size = <0x20000>;
\t\t};

'''

if marker not in text:
    raise SystemExit("could not find the Flint 3 mlo memory marker")

text = text.replace(marker, block + marker, 1)
path.write_text(text, encoding="utf-8")
PY

grep -Fq 'ramoops@4da00000 {' "$DTS" || {
  echo "Failed to retain the Flint 3 ramoops reservation." >&2
  exit 1
}

git -C "$SOURCE_TREE" add -- "$RELATIVE"
printf 'RAMOOPS-RETAINED\t%s\n' "$RELATIVE" >> "$MANIFEST"

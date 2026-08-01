#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE_SOURCE="${1:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"
SECONDARY_COMMIT="${2:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"
MANIFEST="${3:?usage: apply-source-overlays.sh <candidate-source> <secondary-commit> <manifest>}"

[[ -d "$CANDIDATE_SOURCE/.git" ]] || {
	echo "Candidate source is not a Git checkout: $CANDIDATE_SOURCE" >&2
	exit 1
}
[[ -s "$PROJECT_ROOT/source-overlays.conf" ]] || {
	echo "source-overlays.conf is missing or empty." >&2
	exit 1
}

git -C "$CANDIDATE_SOURCE" cat-file -e "$SECONDARY_COMMIT^{commit}"
mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"

printf 'SOURCE OVERLAY MANIFEST\n' >> "$MANIFEST"
printf 'secondary-commit=%s\n\n' "$SECONDARY_COMMIT" >> "$MANIFEST"

applied=0
already=0
missing=0

while IFS= read -r path; do
	[[ -n "$path" && "$path" != \#* ]] || continue
	case "$path" in
		/*|*'..'*)
			echo "Unsafe overlay path: $path" >&2
			exit 1
			;;
	esac

	if ! git -C "$CANDIDATE_SOURCE" cat-file -e "$SECONDARY_COMMIT:$path" 2>/dev/null; then
		printf 'MISSING\t%s\n' "$path" >> "$MANIFEST"
		missing=$((missing + 1))
		continue
	fi

	before='absent'
	if [[ -e "$CANDIDATE_SOURCE/$path" ]]; then
		before="$(sha256sum "$CANDIDATE_SOURCE/$path" | awk '{print $1}')"
	fi
	after="$(git -C "$CANDIDATE_SOURCE" show "$SECONDARY_COMMIT:$path" | sha256sum | awk '{print $1}')"

	if [[ "$before" == "$after" ]]; then
		printf 'ALREADY\t%s\t%s\n' "$after" "$path" >> "$MANIFEST"
		already=$((already + 1))
		continue
	fi

	git -C "$CANDIDATE_SOURCE" checkout "$SECONDARY_COMMIT" -- "$path"
	printf 'APPLIED\t%s\t%s\t%s\n' "$before" "$after" "$path" >> "$MANIFEST"
	applied=$((applied + 1))
done < "$PROJECT_ROOT/source-overlays.conf"

if ! git -C "$CANDIDATE_SOURCE" diff --cached --quiet; then
	git -C "$CANDIDATE_SOURCE" config user.name 'DuskyProjects Nightly Builder'
	git -C "$CANDIDATE_SOURCE" config user.email 'actions@users.noreply.github.com'
	git -C "$CANDIDATE_SOURCE" commit -m "Apply Flint-specific secondary source overlays"
fi

printf '\nSUMMARY applied=%d already=%d missing=%d\n' "$applied" "$already" "$missing" >> "$MANIFEST"
echo "Source overlays refreshed: applied=$applied already=$already missing=$missing"

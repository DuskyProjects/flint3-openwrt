#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE_SOURCE="${1:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
SOURCE_CACHE="${2:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
QUEUE_DIR="${3:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
MANIFEST="${4:?usage: refresh-patches.sh <candidate-source> <source-cache> <queue-dir> <manifest>}"
REFRESH_EXTERNAL_PATCHES="${REFRESH_EXTERNAL_PATCHES:-1}"

[[ -d "$CANDIDATE_SOURCE/.git" ]] || {
	echo "Candidate source is not a Git checkout: $CANDIDATE_SOURCE" >&2
	exit 1
}
[[ -s "$PROJECT_ROOT/patch-sources.conf" ]] || {
	echo "patch-sources.conf is missing or empty." >&2
	exit 1
}

rm -rf "$QUEUE_DIR"
mkdir -p "$QUEUE_DIR" "$SOURCE_CACHE" "$(dirname "$MANIFEST")"
: > "$MANIFEST"

printf 'PATCH INTAKE MANIFEST\n' >> "$MANIFEST"
printf 'candidate=%s\n' "$(git -C "$CANDIDATE_SOURCE" rev-parse HEAD)" >> "$MANIFEST"
printf 'external-refresh=%s\n\n' "$REFRESH_EXTERNAL_PATCHES" >> "$MANIFEST"

# The committed queue is the reviewed fallback and is copied fresh every run.
if compgen -G "$PROJECT_ROOT/patches/mac80211-ath12k/*.patch" >/dev/null; then
	mkdir -p "$QUEUE_DIR/mac80211-ath12k"
	for patch in "$PROJECT_ROOT"/patches/mac80211-ath12k/*.patch; do
		install -m 0644 "$patch" "$QUEUE_DIR/mac80211-ath12k/$(basename "$patch")"
		printf 'LOCAL\t%s\t%s\n' \
			"$(sha256sum "$patch" | awk '{print $1}')" \
			"${patch#$PROJECT_ROOT/}" >> "$MANIFEST"
	done
fi

if [[ "$REFRESH_EXTERNAL_PATCHES" != 1 ]]; then
	printf '\nExternal patch intake disabled for this fallback candidate.\n' >> "$MANIFEST"
	exit 0
fi

# Only patch-file locations that OpenWrt itself consumes are inspected. Broad
# source-tree commits are integrated by the selected Flint 3 source merge, not
# by blindly applying arbitrary commits from unrelated development branches.
PATCH_ROOTS=(
	package/kernel/mac80211/patches/ath12k
	target/linux/qualcommbe/patches-6.18
	target/linux/generic/backport-6.18
	target/linux/generic/pending-6.18
	package/network/services/hostapd/patches
)
KEYWORDS='ath12k|ipq5332|qcn9274|gl-be9300|rtl8372|rtl837x|qcom.*ppe|\bppe\b|edma|multi[- ]link|\bmlo\b|remoteproc|\bpas\b|qrtr|dfs|ap_vlan|wds'

clone_sparse_source() {
	local id="$1" repository="$2" branch="$3" destination="$4"
	if [[ ! -d "$destination/.git" ]]; then
		git clone --depth=1 --filter=blob:none --sparse --single-branch \
			--branch "$branch" "https://github.com/$repository.git" "$destination"
	else
		git -C "$destination" fetch --depth=1 origin "$branch"
		git -C "$destination" checkout --detach FETCH_HEAD
	fi
	git -C "$destination" sparse-checkout set --no-cone "${PATCH_ROOTS[@]}"
	printf 'SOURCE\t%s\t%s\t%s\t%s\n' \
		"$id" "$repository" "$branch" "$(git -C "$destination" rev-parse HEAD)" >> "$MANIFEST"
}

patch_id() {
	git patch-id --stable < "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

declare -A SEEN_PATCH_IDS=()
conflict=0
imported=0
already=0
ignored=0

while IFS='|' read -r id repository branch; do
	[[ -n "$id" && "$id" != \#* ]] || continue
	destination="$SOURCE_CACHE/$id"
	clone_sparse_source "$id" "$repository" "$branch" "$destination"

	for root in "${PATCH_ROOTS[@]}"; do
		[[ -d "$destination/$root" ]] || continue
		while IFS= read -r patch; do
			relative="${patch#$destination/}"

			# Every ath12k patch is relevant. Other trees require a Flint/QCA
			# keyword in the patch subject or content to avoid importing the
			# complete generic kernel patch stack.
			if [[ "$relative" != package/kernel/mac80211/patches/ath12k/* ]] && \
			   ! grep -Eiq "$KEYWORDS" "$patch"; then
				ignored=$((ignored + 1))
				continue
			fi

			pid="$(patch_id "$patch")"
			if [[ -n "$pid" && -n "${SEEN_PATCH_IDS[$pid]:-}" ]]; then
				printf 'DUPLICATE\t%s\t%s\t%s\n' "$id" "$pid" "$relative" >> "$MANIFEST"
				continue
			fi
			[[ -n "$pid" ]] && SEEN_PATCH_IDS[$pid]="$relative"

			target="$CANDIDATE_SOURCE/$relative"
			if [[ -e "$target" ]]; then
				if cmp -s "$patch" "$target"; then
					printf 'ALREADY\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
					already=$((already + 1))
					continue
				fi

				target_pid="$(patch_id "$target")"
				if [[ -n "$pid" && "$pid" == "$target_pid" ]]; then
					printf 'EQUIVALENT\t%s\t%s\t%s\n' "$id" "$pid" "$relative" >> "$MANIFEST"
					already=$((already + 1))
					continue
				fi

				printf 'CONFLICT\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
				conflict=1
				continue
			fi

			mkdir -p "$(dirname "$target")"
			install -m 0644 "$patch" "$target"
			printf 'IMPORTED\t%s\t%s\t%s\n' "$id" "${pid:-no-patch-id}" "$relative" >> "$MANIFEST"
			imported=$((imported + 1))
		done < <(find "$destination/$root" -type f -name '*.patch' -print | sort)
	done
done < "$PROJECT_ROOT/patch-sources.conf"

printf '\nSUMMARY imported=%d already=%d ignored=%d conflicts=%d\n' \
	"$imported" "$already" "$ignored" "$conflict" >> "$MANIFEST"

# A filename collision with different patch content is never silently resolved.
# The caller can retry the same source candidate with external intake disabled.
if (( conflict != 0 )); then
	echo "External patch refresh found conflicting patch files; see $MANIFEST" >&2
	exit 2
fi

echo "Patch intake refreshed: imported=$imported already=$already ignored=$ignored"

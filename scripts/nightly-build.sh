#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

BASE_REPOSITORY="${BASE_REPOSITORY:-perceival/openwrt-flint3}"
BASE_BRANCH="${BASE_BRANCH:-flint3-be9300}"
OVERLAY_REPOSITORY="${OVERLAY_REPOSITORY:-KakatkarAkshay/openwrt}"
OVERLAY_BRANCH="${OVERLAY_BRANCH:-gl-be9300}"
MAX_HISTORY="${MAX_HISTORY:-3}"
MAX_BUILD_ATTEMPTS="${MAX_BUILD_ATTEMPTS:-8}"
JOBS="${JOBS:-4}"

PINNED_PACKAGES_COMMIT="$PACKAGES_FEED_COMMIT"
PINNED_LUCI_COMMIT="$LUCI_FEED_COMMIT"
PINNED_FOOTSTRAP_COMMIT="$FOOTSTRAP_COMMIT"
PINNED_FOOTSTRAP_VERSION="$FOOTSTRAP_VERSION"

NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
SOURCE_ROOT="$NIGHTLY_ROOT/sources"
PATCH_SOURCE_CACHE="$NIGHTLY_ROOT/patch-sources"
ATTEMPT_ROOT="$NIGHTLY_ROOT/attempts"
CCACHE_ROOT="$NIGHTLY_ROOT/ccache"
RELEASE_DIR="$PROJECT_ROOT/release"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

rm -rf "$SOURCE_ROOT" "$ATTEMPT_ROOT" "$RELEASE_DIR"
mkdir -p "$SOURCE_ROOT" "$PATCH_SOURCE_CACHE" "$ATTEMPT_ROOT" "$CCACHE_ROOT" "$RELEASE_DIR"

latest_head() {
	local repository="$1" fallback="$2" head
	head="$({ git ls-remote "https://github.com/$repository.git" HEAD 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
	printf '%s\n' "${head:-$fallback}"
}

clone_history() {
	local repository="$1" branch="$2" destination="$3"
	git clone --no-checkout --single-branch --branch "$branch" \
		"https://github.com/$repository.git" "$destination"
	git -C "$destination" rev-parse --verify "origin/$branch^{commit}" >/dev/null
}

release_field() {
	local body="$1" field="$2"
	printf '%s\n' "$body" | sed -n "s/^<!-- ${field}: \(.*\) -->$/\1/p" | head -n1
}

append_commit_changelog() {
	local repository="$1" previous="$2" current="$3" heading="$4"
	printf '### %s\n\n' "$heading"
	if [[ -n "$previous" ]] &&
	   git -C "$repository" cat-file -e "$previous^{commit}" 2>/dev/null &&
	   git -C "$repository" merge-base --is-ancestor "$previous" "$current"; then
		if [[ "$previous" == "$current" ]]; then
			printf 'No source commits changed.\n\n'
		else
			git -C "$repository" log --no-merges --format='- `%h` %s' "$previous..$current" | head -n 40
			printf '\n'
		fi
	else
		git -C "$repository" log --no-merges --format='- `%h` %s' --max-count=12 "$current"
		printf '\n'
	fi
}

BASE_MIRROR="$SOURCE_ROOT/perceival"
OVERLAY_MIRROR="$SOURCE_ROOT/kakatkar"
clone_history "$BASE_REPOSITORY" "$BASE_BRANCH" "$BASE_MIRROR"
clone_history "$OVERLAY_REPOSITORY" "$OVERLAY_BRANCH" "$OVERLAY_MIRROR"

mapfile -t BASE_HISTORY < <(
	git -C "$BASE_MIRROR" log --first-parent --max-count="$MAX_HISTORY" --format='%ct|%H' "origin/$BASE_BRANCH"
)
mapfile -t OVERLAY_HISTORY < <(
	git -C "$OVERLAY_MIRROR" log --first-parent --max-count="$MAX_HISTORY" --format='%ct|%H' "origin/$OVERLAY_BRANCH"
)
[[ ${#BASE_HISTORY[@]} -gt 0 && ${#OVERLAY_HISTORY[@]} -gt 0 ]] || {
	echo "Could not enumerate recent Flint 3 source revisions." >&2
	exit 1
}

PAIR_FILE="$NIGHTLY_ROOT/source-pairs.txt"
: > "$PAIR_FILE"
for base_row in "${BASE_HISTORY[@]}"; do
	IFS='|' read -r base_time base_commit <<< "$base_row"
	for overlay_row in "${OVERLAY_HISTORY[@]}"; do
		IFS='|' read -r overlay_time overlay_commit <<< "$overlay_row"
		printf '%s|%s|%s|%s|%s\n' \
			"$((base_time + overlay_time))" "$base_time" "$base_commit" "$overlay_time" "$overlay_commit" >> "$PAIR_FILE"
	done
done
sort -t'|' -k1,1nr -k2,2nr -k4,4nr -o "$PAIR_FILE" "$PAIR_FILE"

LATEST_PACKAGES_COMMIT="$(latest_head "$PACKAGES_FEED_REPOSITORY" "$PINNED_PACKAGES_COMMIT")"
LATEST_LUCI_COMMIT="$(latest_head "$LUCI_FEED_REPOSITORY" "$PINNED_LUCI_COMMIT")"
LATEST_FOOTSTRAP_COMMIT="$(latest_head "$FOOTSTRAP_REPOSITORY" "$PINNED_FOOTSTRAP_COMMIT")"
LATEST_FOOTSTRAP_VERSION="0.0.0_git${DATE_UTC}_${LATEST_FOOTSTRAP_COMMIT:0:8}"

FEED_TIERS=(
	"latest|$LATEST_PACKAGES_COMMIT|$LATEST_LUCI_COMMIT|$LATEST_FOOTSTRAP_COMMIT|$LATEST_FOOTSTRAP_VERSION"
)
if [[ "$LATEST_PACKAGES_COMMIT|$LATEST_LUCI_COMMIT|$LATEST_FOOTSTRAP_COMMIT" != "$PINNED_PACKAGES_COMMIT|$PINNED_LUCI_COMMIT|$PINNED_FOOTSTRAP_COMMIT" ]]; then
	FEED_TIERS+=(
		"known-good|$PINNED_PACKAGES_COMMIT|$PINNED_LUCI_COMMIT|$PINNED_FOOTSTRAP_COMMIT|$PINNED_FOOTSTRAP_VERSION"
	)
fi

OVERLAY_TIERS=("flint-overlays|1" "base-only|0")
PATCH_TIERS=("refreshed|1" "curated-fallback|0")

attempt=0
success=0
successful_base=''
successful_overlay=''
successful_overlay_tier=''
successful_patch_tier=''
successful_feed_tier=''
successful_packages=''
successful_luci=''
successful_footstrap=''
successful_output=''
successful_patch_manifest=''
successful_overlay_manifest=''

while IFS='|' read -r _score _base_time base_commit _overlay_time overlay_commit; do
	candidate_id="${base_commit:0:8}-${overlay_commit:0:8}"
	base_candidate="$ATTEMPT_ROOT/base-$candidate_id"
	rm -rf "$base_candidate"
	git clone --local --no-hardlinks "$BASE_MIRROR" "$base_candidate"
	git -C "$base_candidate" checkout --detach "$base_commit"
	git -C "$base_candidate" fetch --no-tags "$OVERLAY_MIRROR" "$overlay_commit"

	for overlay_tier in "${OVERLAY_TIERS[@]}"; do
		IFS='|' read -r overlay_tier_name apply_overlays <<< "$overlay_tier"
		integrated_source="$ATTEMPT_ROOT/integrated-$candidate_id-$overlay_tier_name"
		overlay_manifest="$ATTEMPT_ROOT/overlays-$candidate_id-$overlay_tier_name.txt"
		rm -rf "$integrated_source"
		git clone --local --no-hardlinks "$base_candidate" "$integrated_source"

		if [[ "$apply_overlays" == 1 ]]; then
			if ! bash "$PROJECT_ROOT/scripts/apply-source-overlays.sh" \
				"$integrated_source" "$overlay_commit" "$overlay_manifest"; then
				echo "Flint overlay tier was not usable for $candidate_id."
				continue
			fi
		else
			{
				printf 'SOURCE OVERLAY MANIFEST\n'
				printf 'secondary-commit=%s\n' "$overlay_commit"
				printf 'tier=base-only\n'
				printf 'SUMMARY applied=0 already=0 missing=0\n'
			} > "$overlay_manifest"
		fi

		for patch_tier in "${PATCH_TIERS[@]}"; do
			IFS='|' read -r patch_tier_name refresh_external <<< "$patch_tier"
			prepared_source="$ATTEMPT_ROOT/prepared-$candidate_id-$overlay_tier_name-$patch_tier_name"
			queue_root="$ATTEMPT_ROOT/queue-$candidate_id-$overlay_tier_name-$patch_tier_name"
			patch_manifest="$ATTEMPT_ROOT/patches-$candidate_id-$overlay_tier_name-$patch_tier_name.txt"
			rm -rf "$prepared_source" "$queue_root"
			git clone --local --no-hardlinks "$integrated_source" "$prepared_source"

			if ! REFRESH_EXTERNAL_PATCHES="$refresh_external" \
				bash "$PROJECT_ROOT/scripts/refresh-patches.sh" \
					"$prepared_source" "$PATCH_SOURCE_CACHE" "$queue_root" "$patch_manifest"; then
				echo "Patch tier $patch_tier_name was not usable for $candidate_id."
				continue
			fi

			source_record="$ATTEMPT_ROOT/INTEGRATED-SOURCES-$candidate_id-$overlay_tier_name-$patch_tier_name.txt"
			cat > "$source_record" <<SOURCES
Base repository:      $BASE_REPOSITORY
Base branch:          $BASE_BRANCH
Base commit:          $base_commit
Overlay repository:   $OVERLAY_REPOSITORY
Overlay branch:       $OVERLAY_BRANCH
Overlay commit:       $overlay_commit
Integrated commit:    $(git -C "$prepared_source" rev-parse HEAD)
Overlay tier:         $overlay_tier_name
Patch tier:           $patch_tier_name
SOURCES

			for feed_tier in "${FEED_TIERS[@]}"; do
				if (( attempt >= MAX_BUILD_ATTEMPTS )); then
					break 4
				fi
				IFS='|' read -r tier_name packages_commit luci_commit footstrap_commit footstrap_version <<< "$feed_tier"
				attempt=$((attempt + 1))
				attempt_dir="$ATTEMPT_ROOT/build-$attempt-$candidate_id-$overlay_tier_name-$patch_tier_name-$tier_name"
				output_dir="$attempt_dir/output"
				log_file="$attempt_dir/build.log"
				mkdir -p "$attempt_dir"

				echo "============================================================"
				echo "Nightly build attempt $attempt of $MAX_BUILD_ATTEMPTS"
				echo "Perceival base:     $base_commit"
				echo "Kakatkar overlays:  $overlay_commit ($overlay_tier_name)"
				echo "Patch intake:       $patch_tier_name"
				echo "Feeds:              $tier_name"
				echo "============================================================"

				if env \
					OPENWRT_LOCAL_SOURCE="$prepared_source" \
					OPENWRT_REPOSITORY="$BASE_REPOSITORY with selected Flint overlays from $OVERLAY_REPOSITORY" \
					OPENWRT_BRANCH="$BASE_BRANCH + selective $OVERLAY_BRANCH overlays" \
					OPENWRT_COMMIT="$(git -C "$prepared_source" rev-parse HEAD)" \
					PACKAGES_FEED_COMMIT="$packages_commit" \
					LUCI_FEED_COMMIT="$luci_commit" \
					FOOTSTRAP_COMMIT="$footstrap_commit" \
					FOOTSTRAP_VERSION="$footstrap_version" \
					FIRMWARE_BUILD_LABEL="nightly-integrated" \
					MERGED_SOURCE_RECORD="$source_record" \
					ATH12K_PATCH_DIR="$queue_root/mac80211-ath12k" \
					WORK_ROOT="$attempt_dir/work" \
					OUTPUT_DIR="$output_dir" \
					DOWNLOAD_CACHE_DIR="${DOWNLOAD_CACHE_DIR:-$NIGHTLY_ROOT/dl}" \
					CCACHE_DIR="$CCACHE_ROOT" \
					JOBS="$JOBS" \
					bash "$PROJECT_ROOT/scripts/build.sh" >"$log_file" 2>&1; then
					success=1
					successful_base="$base_commit"
					successful_overlay="$overlay_commit"
					successful_overlay_tier="$overlay_tier_name"
					successful_patch_tier="$patch_tier_name"
					successful_feed_tier="$tier_name"
					successful_packages="$packages_commit"
					successful_luci="$luci_commit"
					successful_footstrap="$footstrap_commit"
					successful_output="$output_dir"
					successful_patch_manifest="$patch_manifest"
					successful_overlay_manifest="$overlay_manifest"
					tail -n 80 "$log_file"
					break 4
				fi

				echo "Candidate did not compile; trying the next newest safe combination."
				tail -n 120 "$log_file" || true
			done
		done
	done
done < "$PAIR_FILE"

(( success == 1 )) || {
	echo "No tested recent Flint-specific source/feed/patch combination compiled successfully." >&2
	exit 1
}

mapfile -t FACTORY_IMAGES < <(find "$successful_output" -maxdepth 1 -type f -name '*factory.bin' -print)
mapfile -t SYSUPGRADE_IMAGES < <(find "$successful_output" -maxdepth 1 -type f -name '*sysupgrade.bin' -print)
[[ ${#FACTORY_IMAGES[@]} -eq 1 && ${#SYSUPGRADE_IMAGES[@]} -eq 1 ]] || {
	echo "Successful build did not contain exactly two firmware images." >&2
	exit 1
}

FACTORY_RELEASE="$RELEASE_DIR/flint3-full-factory.bin"
SYSUPGRADE_RELEASE="$RELEASE_DIR/flint3-sysupgrade.bin"
cp -v "${FACTORY_IMAGES[0]}" "$FACTORY_RELEASE"
cp -v "${SYSUPGRADE_IMAGES[0]}" "$SYSUPGRADE_RELEASE"
[[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2 ]]

previous_body=''
previous_base=''
previous_overlay=''
if command -v gh >/dev/null 2>&1 && [[ -n "${GH_TOKEN:-}" ]]; then
	previous_tag="$(gh release list --limit 100 --json tagName,isPrerelease,publishedAt \
		--jq '[.[] | select(.isPrerelease == true and (.tagName | startswith("nightly-")))] | sort_by(.publishedAt) | last | .tagName // ""' \
		2>/dev/null || true)"
	if [[ -n "$previous_tag" ]]; then
		previous_body="$(gh release view "$previous_tag" --json body --jq .body 2>/dev/null || true)"
		previous_base="$(release_field "$previous_body" base-source)"
		previous_overlay="$(release_field "$previous_body" overlay-source)"
	fi
fi

CHANGELOG_FILE="$PROJECT_ROOT/release-notes.md"
{
	printf '<!-- base-source: %s -->\n' "$successful_base"
	printf '<!-- overlay-source: %s -->\n' "$successful_overlay"
	printf '<!-- packages-source: %s -->\n' "$successful_packages"
	printf '<!-- luci-source: %s -->\n' "$successful_luci"
	printf '<!-- footstrap-source: %s -->\n\n' "$successful_footstrap"
	printf '# Flint 3 integrated nightly — %s\n\n' "$DATE_DISPLAY"
	printf 'Newest tested Flint-specific source combination that passed overlay intake, patch intake, privacy checks, package validation, factory-image validation, and compilation.\n\n'
	printf '## Selected inputs\n\n'
	printf -- '- Perceival base: `%s@%s`\n' "$BASE_REPOSITORY" "$successful_base"
	printf -- '- Kakatkar Flint overlays: `%s@%s`\n' "$OVERLAY_REPOSITORY" "$successful_overlay"
	printf -- '- Overlay tier: `%s`\n' "$successful_overlay_tier"
	printf -- '- Patch intake tier: `%s`\n' "$successful_patch_tier"
	printf -- '- Package feed: `%s@%s`\n' "$PACKAGES_FEED_REPOSITORY" "$successful_packages"
	printf -- '- LuCI feed: `%s@%s`\n' "$LUCI_FEED_REPOSITORY" "$successful_luci"
	printf -- '- Footstrap: `%s@%s`\n' "$FOOTSTRAP_REPOSITORY" "$successful_footstrap"
	printf -- '- Feed tier: `%s`\n\n' "$successful_feed_tier"

	printf '## Changelog\n\n'
	append_commit_changelog "$BASE_MIRROR" "$previous_base" "$successful_base" "Perceival base changes"
	append_commit_changelog "$OVERLAY_MIRROR" "$previous_overlay" "$successful_overlay" "Kakatkar overlay-source changes"

	printf '### Flint-specific source overlays\n\n'
	if [[ -s "$successful_overlay_manifest" ]]; then
		grep -E '^(APPLIED|ALREADY|MISSING|SUMMARY)' "$successful_overlay_manifest" |
			sed 's/^/- `/' | sed 's/$/`/'
	else
		printf 'No source-overlay manifest was generated.\n'
	fi
	printf '\n\n'

	printf '### Refreshed patch intake\n\n'
	if [[ -s "$successful_patch_manifest" ]]; then
		grep -E '^(SOURCE|IMPORTED|ALREADY|EQUIVALENT|CONFLICT|SUMMARY)' "$successful_patch_manifest" |
			sed 's/^/- `/' | sed 's/$/`/'
	else
		printf 'No patch manifest was generated.\n'
	fi
	printf '\n\n'

	printf '## Image checksums\n\n```text\n'
	sha256sum "$FACTORY_RELEASE" "$SYSUPGRADE_RELEASE" | sed "s#$PROJECT_ROOT/##"
	printf '```\n\n'
	printf 'Release assets contain only the full factory image and the sysupgrade image.\n'
} > "$CHANGELOG_FILE"

cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG='nightly-$DATE_UTC'
RELEASE_TITLE='Flint 3 Nightly $DATE_DISPLAY'
FACTORY_FILE='$FACTORY_RELEASE'
SYSUPGRADE_FILE='$SYSUPGRADE_RELEASE'
ENV

sha256sum "$FACTORY_RELEASE" "$SYSUPGRADE_RELEASE"
echo "Selected newest successful Flint-specific candidate after $attempt build attempt(s)."

#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/build.env"

BASE_REPOSITORY="${BASE_REPOSITORY:-perceival/openwrt-flint3}"
BASE_BRANCH="${BASE_BRANCH:-flint3-be9300}"
PATCH_REPOSITORY="${PATCH_REPOSITORY:-KakatkarAkshay/openwrt}"
PATCH_BRANCH="${PATCH_BRANCH:-gl-be9300}"
MAX_HISTORY="${MAX_HISTORY:-3}"
MAX_BUILD_ATTEMPTS="${MAX_BUILD_ATTEMPTS:-4}"
JOBS="${JOBS:-4}"

PINNED_PACKAGES_COMMIT="$PACKAGES_FEED_COMMIT"
PINNED_LUCI_COMMIT="$LUCI_FEED_COMMIT"
PINNED_FOOTSTRAP_COMMIT="$FOOTSTRAP_COMMIT"
PINNED_FOOTSTRAP_VERSION="$FOOTSTRAP_VERSION"

NIGHTLY_ROOT="${NIGHTLY_ROOT:-$PROJECT_ROOT/nightly-work}"
SOURCE_ROOT="$NIGHTLY_ROOT/sources"
ATTEMPT_ROOT="$NIGHTLY_ROOT/attempts"
RELEASE_DIR="$PROJECT_ROOT/release"
DATE_UTC="$(date -u +%Y%m%d)"
DATE_DISPLAY="$(date -u +%Y-%m-%d)"

rm -rf "$NIGHTLY_ROOT" "$RELEASE_DIR"
mkdir -p "$SOURCE_ROOT" "$ATTEMPT_ROOT" "$RELEASE_DIR"

latest_head() {
	local repository="$1"
	local fallback="$2"
	local head
	head="$(git ls-remote "https://github.com/$repository.git" HEAD 2>/dev/null | awk 'NR == 1 { print $1 }')"
	printf '%s\n' "${head:-$fallback}"
}

clone_history() {
	local repository="$1"
	local branch="$2"
	local destination="$3"
	git clone --filter=blob:none --no-checkout --single-branch \
		--branch "$branch" "https://github.com/$repository.git" "$destination"
	git -C "$destination" rev-parse --verify "origin/$branch^{commit}" >/dev/null
}

BASE_MIRROR="$SOURCE_ROOT/perceival"
PATCH_MIRROR="$SOURCE_ROOT/kakatkar"
clone_history "$BASE_REPOSITORY" "$BASE_BRANCH" "$BASE_MIRROR"
clone_history "$PATCH_REPOSITORY" "$PATCH_BRANCH" "$PATCH_MIRROR"

mapfile -t BASE_HISTORY < <(
	git -C "$BASE_MIRROR" log --first-parent --max-count="$MAX_HISTORY" \
		--format='%ct|%H' "origin/$BASE_BRANCH"
)
mapfile -t PATCH_HISTORY < <(
	git -C "$PATCH_MIRROR" log --first-parent --max-count="$MAX_HISTORY" \
		--format='%ct|%H' "origin/$PATCH_BRANCH"
)

[[ ${#BASE_HISTORY[@]} -gt 0 && ${#PATCH_HISTORY[@]} -gt 0 ]] || {
	echo "Could not enumerate recent Flint 3 source revisions." >&2
	exit 1
}

PAIR_FILE="$NIGHTLY_ROOT/source-pairs.txt"
: > "$PAIR_FILE"
for base_row in "${BASE_HISTORY[@]}"; do
	IFS='|' read -r base_time base_commit <<< "$base_row"
	for patch_row in "${PATCH_HISTORY[@]}"; do
		IFS='|' read -r patch_time patch_commit <<< "$patch_row"
		score=$((base_time + patch_time))
		printf '%s|%s|%s|%s|%s\n' \
			"$score" "$base_time" "$base_commit" "$patch_time" "$patch_commit" \
			>> "$PAIR_FILE"
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
if [[ "$LATEST_PACKAGES_COMMIT|$LATEST_LUCI_COMMIT|$LATEST_FOOTSTRAP_COMMIT" != \
      "$PINNED_PACKAGES_COMMIT|$PINNED_LUCI_COMMIT|$PINNED_FOOTSTRAP_COMMIT" ]]; then
	FEED_TIERS+=(
		"known-good|$PINNED_PACKAGES_COMMIT|$PINNED_LUCI_COMMIT|$PINNED_FOOTSTRAP_COMMIT|$PINNED_FOOTSTRAP_VERSION"
	)
fi

attempt=0
success=0
successful_base=''
successful_patch=''
successful_feed_tier=''
successful_packages=''
successful_luci=''
successful_footstrap=''
successful_output=''

while IFS='|' read -r _score _base_time base_commit _patch_time patch_commit; do
	candidate_id="${base_commit:0:8}-${patch_commit:0:8}"
	candidate_source="$ATTEMPT_ROOT/source-$candidate_id"
	rm -rf "$candidate_source"
	git clone --local --no-hardlinks "$BASE_MIRROR" "$candidate_source"
	git -C "$candidate_source" checkout --detach "$base_commit"
	git -C "$candidate_source" fetch --no-tags "$PATCH_MIRROR" "$patch_commit"
	git -C "$candidate_source" config user.name 'DuskyProjects Nightly Builder'
	git -C "$candidate_source" config user.email 'actions@users.noreply.github.com'

	if ! git -C "$candidate_source" merge --no-ff --no-edit --no-gpg-sign FETCH_HEAD; then
		git -C "$candidate_source" merge --abort >/dev/null 2>&1 || true
		echo "Skipping source pair with merge conflicts: $candidate_id"
		continue
	fi

	source_record="$candidate_source/MERGED-SOURCES.txt"
	cat > "$source_record" <<SOURCES
Base repository:   $BASE_REPOSITORY
Base branch:       $BASE_BRANCH
Base commit:       $base_commit
Patch repository:  $PATCH_REPOSITORY
Patch branch:      $PATCH_BRANCH
Patch commit:      $patch_commit
Merged commit:     $(git -C "$candidate_source" rev-parse HEAD)
SOURCES

	for feed_tier in "${FEED_TIERS[@]}"; do
		IFS='|' read -r tier_name packages_commit luci_commit footstrap_commit footstrap_version <<< "$feed_tier"
		attempt=$((attempt + 1))
		if (( attempt > MAX_BUILD_ATTEMPTS )); then
			break 2
		fi

		attempt_dir="$ATTEMPT_ROOT/build-$attempt-$candidate_id-$tier_name"
		output_dir="$attempt_dir/output"
		log_file="$attempt_dir/build.log"
		mkdir -p "$attempt_dir"

		echo "============================================================"
		echo "Nightly build attempt $attempt of $MAX_BUILD_ATTEMPTS"
		echo "Perceival: $base_commit"
		echo "Kakatkar:  $patch_commit"
		echo "Feeds:      $tier_name"
		echo "============================================================"

		if env \
			OPENWRT_LOCAL_SOURCE="$candidate_source" \
			OPENWRT_REPOSITORY="$BASE_REPOSITORY + $PATCH_REPOSITORY" \
			OPENWRT_BRANCH="$BASE_BRANCH + $PATCH_BRANCH" \
			OPENWRT_COMMIT="$(git -C "$candidate_source" rev-parse HEAD)" \
			PACKAGES_FEED_COMMIT="$packages_commit" \
			LUCI_FEED_COMMIT="$luci_commit" \
			FOOTSTRAP_COMMIT="$footstrap_commit" \
			FOOTSTRAP_VERSION="$footstrap_version" \
			BUILD_VARIANT="nightly-merged" \
			MERGED_SOURCE_RECORD="$source_record" \
			WORK_ROOT="$attempt_dir/work" \
			OUTPUT_DIR="$output_dir" \
			CCACHE_DIR="$NIGHTLY_ROOT/ccache" \
			JOBS="$JOBS" \
			bash "$PROJECT_ROOT/scripts/build.sh" >"$log_file" 2>&1; then
			success=1
			successful_base="$base_commit"
			successful_patch="$patch_commit"
			successful_feed_tier="$tier_name"
			successful_packages="$packages_commit"
			successful_luci="$luci_commit"
			successful_footstrap="$footstrap_commit"
			successful_output="$output_dir"
			tail -n 80 "$log_file"
			break 2
		fi

		echo "Candidate did not compile; trying the next newest combination."
		tail -n 120 "$log_file" || true
	done
done < "$PAIR_FILE"

(( success == 1 )) || {
	echo "No tested recent merged source/feed combination compiled successfully." >&2
	exit 1
}

mapfile -t FACTORY_IMAGES < <(
	find "$successful_output" -maxdepth 1 -type f -name '*factory.bin' -print
)
mapfile -t SYSUPGRADE_IMAGES < <(
	find "$successful_output" -maxdepth 1 -type f -name '*sysupgrade.bin' -print
)
[[ ${#FACTORY_IMAGES[@]} -eq 1 && ${#SYSUPGRADE_IMAGES[@]} -eq 1 ]] || {
	echo "Successful build did not contain exactly two firmware images." >&2
	exit 1
}

FACTORY_RELEASE="$RELEASE_DIR/flint3-full-factory.bin"
SYSUPGRADE_RELEASE="$RELEASE_DIR/flint3-sysupgrade.bin"
cp -v "${FACTORY_IMAGES[0]}" "$FACTORY_RELEASE"
cp -v "${SYSUPGRADE_IMAGES[0]}" "$SYSUPGRADE_RELEASE"

[[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.bin' | wc -l)" -eq 2 ]] || {
	echo "Release directory must contain exactly two binary images." >&2
	exit 1
}

cat > "$PROJECT_ROOT/release-notes.md" <<NOTES
Automated merged nightly firmware for the GL.iNet Flint 3 / GL-BE9300.

This run selected the newest tested combination that merged cleanly, passed the privacy and package checks, and compiled successfully.

- Perceival source: \`$BASE_REPOSITORY@$successful_base\`
- Kakatkar source: \`$PATCH_REPOSITORY@$successful_patch\`
- Package feed: \`$PACKAGES_FEED_REPOSITORY@$successful_packages\`
- LuCI feed: \`$LUCI_FEED_REPOSITORY@$successful_luci\`
- Footstrap: \`$FOOTSTRAP_REPOSITORY@$successful_footstrap\`
- Feed tier used: \`$successful_feed_tier\`

Release assets contain only the full factory image and the sysupgrade image.
NOTES

cat > "$PROJECT_ROOT/nightly-release.env" <<ENV
RELEASE_TAG=nightly-$DATE_UTC
RELEASE_TITLE=Flint_3_Nightly_$DATE_DISPLAY
FACTORY_FILE=$FACTORY_RELEASE
SYSUPGRADE_FILE=$SYSUPGRADE_RELEASE
ENV

sha256sum "$FACTORY_RELEASE" "$SYSUPGRADE_RELEASE"
echo "Selected newest successful merged candidate after $attempt build attempt(s)."

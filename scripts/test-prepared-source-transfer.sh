#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

source_repo="$TEST_ROOT/source"
destination="$TEST_ROOT/destination"
mkdir -p "$source_repo"

git -C "$source_repo" init -q -b main
git -C "$source_repo" config user.name 'Prepared Source Test'
git -C "$source_repo" config user.email 'prepared-source@example.invalid'
printf 'base\n' > "$source_repo/payload.txt"
git -C "$source_repo" add payload.txt
git -C "$source_repo" commit -qm base

git -C "$source_repo" checkout -q --detach
printf 'integrated\n' > "$source_repo/payload.txt"
git -C "$source_repo" commit -qam 'local integration commit'
source_head="$(git -C "$source_repo" rev-parse HEAD)"

# Simulate an unrelated temporary remote-tracking ref whose object is not in
# this repository. Fetching only HEAD must ignore it.
mkdir -p "$source_repo/.git/refs/remotes/origin"
printf '%s\n' '1111111111111111111111111111111111111111' \
  > "$source_repo/.git/refs/remotes/origin/flint3-be9300"

mkdir -p "$destination"
git -C "$destination" init -q
git -C "$destination" fetch --no-tags "$source_repo" HEAD >/dev/null
git -C "$destination" checkout -q --detach --force FETCH_HEAD

[[ "$(git -C "$destination" rev-parse HEAD)" == "$source_head" ]]
grep -Fxq integrated "$destination/payload.txt"

echo 'Prepared source HEAD transfer test passed.'

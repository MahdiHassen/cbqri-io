#!/usr/bin/env bash
# apply-patches.sh <tree> <base-tag> <patch-dir>
# Reset branch `cbqri` in <tree> to <base-tag> and `git am` every patch in
# <patch-dir>. To add a patch: commit in src/<tree> on the cbqri branch, then
#   git -C src/<tree> format-patch -o ../../patches/<tree> <base-tag>
set -euo pipefail
tree=$1 base=$2 dir=$3
git -C "$tree" diff --quiet && git -C "$tree" diff --cached --quiet || {
    echo "$tree has uncommitted changes; commit or stash them first" >&2; exit 1; }
git -C "$tree" checkout -q -B cbqri "$base^{commit}"
shopt -s nullglob
patches=("$dir"/*.patch)
(( ${#patches[@]} )) || { echo "$tree: no patches, cbqri == $base"; exit 0; }
git -C "$tree" -c user.name=cbqri -c user.email=cbqri@localhost am -q --3way "${patches[@]}"
echo "$tree: applied ${#patches[@]} patch(es) onto $base"

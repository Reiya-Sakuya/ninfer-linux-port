#!/usr/bin/env bash
# apply.sh — apply the Linux port patches to a fusion-engine-src tree.
#
#   ./apply.sh /path/to/fusion-engine-src        # in place
#
# Runs a full dry-run first: if any hunk does not apply, nothing is written.
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "usage: $0 <path-to>/src-tree/fusion-engine-src" >&2
    exit 2
fi
if [[ ! -d "$TARGET/src/models/qwen3_8_flash_next" ]]; then
    echo "error: $TARGET does not look like fusion-engine-src" >&2
    exit 2
fi

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
mapfile -t PATCHES < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | sort)
if [[ ${#PATCHES[@]} -eq 0 ]]; then
    echo "error: no .patch files in $PATCH_DIR" >&2
    exit 2
fi

echo "==> dry-run: checking ${#PATCHES[@]} patches"
for p in "${PATCHES[@]}"; do
    if ! ( cd "$TARGET" && patch -p1 --dry-run --silent < "$p" ); then
        echo "error: $(basename "$p") does not apply." >&2
        echo "       Target tree is not pristine, or upstream has changed." >&2
        exit 1
    fi
    printf '    ok  %s\n' "$(basename "$p")"
done

echo "==> applying"
for p in "${PATCHES[@]}"; do
    ( cd "$TARGET" && patch -p1 --silent < "$p" )
    printf '    applied  %s\n' "$(basename "$p")"
done

echo
echo "Done. Build with ./build.sh (or see docs/build.md for the manual steps)."

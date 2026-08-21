#!/usr/bin/env bash
# Content-hash verification for every vendored dep source tree in dep/.
#
# Each dep/<name>/ pins a specific upstream point in time via dep/<name>/
# VERSION (a version string or commit SHA). That pin only proves someone
# *typed* the right version — it does not prove the committed source tree
# actually still matches that version byte-for-byte. A hand-edit to a
# vendored .c file (accidental or malicious) leaves VERSION untouched and
# nothing previously caught it. This script closes that gap: each dep also
# carries dep/<name>/SOURCE_SHA256, a manifest hash over its pinned source
# files (excluding build outputs: prebuilt binaries CI writes back after
# building, and the metadata files themselves). `verify` recomputes the
# manifest hash from the working tree and fails loudly on any mismatch.
#
# Usage:
#   tooling/scripts/vendor-verify.sh verify [dep ...]   # default: all deps
#   tooling/scripts/vendor-verify.sh update <dep>        # regenerate SOURCE_SHA256
#
# The manifest hash is: sha256 of the sorted list of "<relpath>  <sha256 of
# file>" lines for every non-excluded file under the dep's source root.
# Hashing a manifest (not a tar) means the result depends only on file
# content and relative path, not on mtimes, permissions, or archive tool
# quirks — reproducible across machines and CI runners.
#
# File list comes from `git ls-files`, not a filesystem `find`: a `find`
# walk picks up whatever happens to be sitting in the working tree —
# gitignored build byproducts (e.g. `./configure && make` output like
# config.h/conftest.c) included — so the hash silently depended on local
# build history instead of only the committed source. That's how dep/tcc's
# recorded hash went stale without anyone editing tracked source: it was
# generated on a tree that had untracked configure/make output sitting in
# dep/tcc/, so those files got baked into the manifest, and a clean CI
# checkout (which only ever materializes tracked files) computed a
# different, correct hash and failed verification. git-scoping this makes
# the hash depend only on what's actually committed, matching what CI
# (and any clean clone) will ever see.
set -euo pipefail

repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$repo_root"

# Per-dep config: source root, and exclude patterns (relative to that root,
# shell glob, matched against the path as found by `find`) for prebuilt
# binaries CI writes back plus any nested build-output directory. Metadata
# files (VERSION, VENDORED_VERSION, SOURCE_SHA256) are excluded unconditionally
# below and don't need to be listed here.
declare -A DEP_ROOT=(
  [sqlite3]="dep/sqlite3"
  [zlib]="dep/zlib"
  [libressl]="dep/libressl"
  [wepoll]="dep/wepoll"
  [tcc]="dep/tcc"
  [luajit]="dep/luajit"
)

declare -A DEP_EXCLUDES=(
  [sqlite3]="*.so *.dylib *.dll"
  [zlib]="*.so *.dylib *.dll"
  [libressl]="linux-x86_64/*"
  [wepoll]="*.dll"
  [tcc]=""
  [luajit]=""
)

ALL_DEPS="sqlite3 zlib libressl wepoll tcc luajit"

# manifest_hash <root> <excludes...>
manifest_hash() {
  local root="$1"
  shift
  local excludes=("$@")
  local f rel skip pat

  git ls-files -z "$root" | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
    rel="${f#"$root"/}"
    case "$rel" in
      VERSION|VENDORED_VERSION|SOURCE_SHA256) continue ;;
    esac
    skip=0
    for pat in "${excludes[@]}"; do
      [ -z "$pat" ] && continue
      case "$rel" in
        $pat) skip=1; break ;;
      esac
    done
    [ "$skip" -eq 1 ] && continue
    printf '%s  %s\n' "$rel" "$(sha256sum "$f" | cut -d' ' -f1)"
  done | sha256sum | cut -d' ' -f1
}

cmd="${1:-}"
case "$cmd" in
  verify)
    shift
    deps=("$@")
    [ "${#deps[@]}" -eq 0 ] && deps=($ALL_DEPS)
    fail=0
    for dep in "${deps[@]}"; do
      root="${DEP_ROOT[$dep]:-}"
      if [ -z "$root" ]; then
        echo "vendor-verify: unknown dep '$dep'" >&2
        fail=1
        continue
      fi
      if [ ! -d "$root" ]; then
        echo "vendor-verify: $dep: $root does not exist, skipping" >&2
        continue
      fi
      recorded_file="$root/SOURCE_SHA256"
      if [ ! -f "$recorded_file" ]; then
        echo "FAIL $dep: no $recorded_file recorded — run 'tooling/scripts/vendor-verify.sh update $dep' after confirming the source is what it should be" >&2
        fail=1
        continue
      fi
      recorded="$(cat "$recorded_file")"
      # shellcheck disable=SC2086
      computed="$(manifest_hash "$root" ${DEP_EXCLUDES[$dep]})"
      if [ "$computed" != "$recorded" ]; then
        echo "FAIL $dep: source tree does not match recorded SOURCE_SHA256" >&2
        echo "  recorded: $recorded" >&2
        echo "  computed: $computed" >&2
        echo "  $root has drifted from its pin (dep/$dep/VERSION) without SOURCE_SHA256 being updated." >&2
        echo "  If this drift is intentional (re-vendored source), regenerate with:" >&2
        echo "    tooling/scripts/vendor-verify.sh update $dep" >&2
        fail=1
      else
        echo "OK $dep: source matches recorded SOURCE_SHA256 ($computed)"
      fi
    done
    exit "$fail"
    ;;
  update)
    dep="${2:-}"
    if [ -z "$dep" ] || [ -z "${DEP_ROOT[$dep]:-}" ]; then
      echo "usage: tooling/scripts/vendor-verify.sh update <dep>" >&2
      echo "  known deps: $ALL_DEPS" >&2
      exit 1
    fi
    root="${DEP_ROOT[$dep]}"
    # shellcheck disable=SC2086
    computed="$(manifest_hash "$root" ${DEP_EXCLUDES[$dep]})"
    echo "$computed" > "$root/SOURCE_SHA256"
    echo "wrote $root/SOURCE_SHA256: $computed"
    ;;
  *)
    echo "usage: tooling/scripts/vendor-verify.sh verify [dep ...]" >&2
    echo "       tooling/scripts/vendor-verify.sh update <dep>" >&2
    exit 1
    ;;
esac

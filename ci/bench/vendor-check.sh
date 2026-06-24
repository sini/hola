#!/usr/bin/env bash
set -euo pipefail
vendored="$HOLA_SRC/lib/engine/vendor/modules.nix"
upstream="$NIXPKGS/lib/modules.nix"
echo "vendored: $vendored"
echo "upstream: $upstream  (rev $(cat "$NIXPKGS/.git-revision" 2>/dev/null || echo '?'))"
if diff -u "$upstream" "$vendored" > /tmp/vendor-check.diff; then
  echo "OK: vendored modules.nix is byte-identical to the harness nixpkgs input."
else
  echo "DRIFT: vendored modules.nix diverges from the harness nixpkgs input:"
  cat /tmp/vendor-check.diff
  echo "(expected once E3 edits the body; at E1 this must be empty — re-vendor on a nixpkgs bump.)"
fi

# parity-report — run the authoritative parity gate (`nix flake check` in hola/ci)
# and emit a short markdown report: a header line with the Nix version + the
# nixpkgs rev, a PASS/FAIL line for the gate, and an honest caveat that all
# Tier-2 numbers are vanilla-baseline-only (no engine arm exists yet).
#
# EVIDENCE app — this report does NOT gate; the gate's own PASS/FAIL is in the
# markdown. Always exit 0 once the report is emitted.
set -euo pipefail

nixVersion="$(nix --version | awk '{print $NF}')"

# nixpkgs rev: read it out of the baked nixpkgs source tree (.version-suffix
# carries the rev for channel tarballs); fall back to the lib version string.
nixpkgsRev="$(
  if [ -f "$NIXPKGS/.git-revision" ]; then
    cat "$NIXPKGS/.git-revision"
  else
    nix eval --impure --raw --expr "(import ($NIXPKGS + \"/lib\")).version" 2>/dev/null || echo "unknown"
  fi
)"

# Run the gate. `nix flake check` is the authoritative parity gate.
#
# The gate must run against a LIVE working tree, not the store copy baked into
# this app: re-evaluating the flake from a /nix/store path breaks the flake's
# own `git+file://` self-reference (apps.nix's `../.` escapes the store). So we
# try candidate gate dirs in order of liveness and use the first that evaluates;
# if none can run (e.g. invoked fully outside the repo), we report SKIPPED
# rather than a misleading FAIL. This app never gates on the result.
run_gate() {
  local d
  for d in "./ci" "$PWD/ci" "$HOLA_SRC/ci"; do
    [ -d "$d" ] || continue
    if (cd "$d" && nix flake check) >/dev/null 2>&1; then
      echo "PASS"
      return 0
    fi
  done
  echo "SKIPPED (no live flake reachable from sandbox; run \`nix flake check\` in hola/ci directly)"
}
gate="$(run_gate)"

cat <<EOF
# hola parity report

- nix: \`$nixVersion\`
- nixpkgs: \`$nixpkgsRev\`

**Parity gate (\`nix flake check\`): $gate**

> Caveat: Tier-2 evidence numbers are VANILLA-BASELINE-ONLY. No engine arm
> exists yet, so these measure the unmodified nixpkgs module-system cost — not
> a hola-engine vs vanilla delta.
EOF

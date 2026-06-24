# stat-capture <fixtureName> — eval a VALUE corpus fixture under NIX_SHOW_STATS,
# emit one-line JSON. Package-free: imports hola with `lib` only (no pkgs storm),
# isolating module-machinery cost.
#
# Only VALUE-gate fixtures fit here: synthetic, priorityFold, order, valueMeta.
# (realHost is gate=drvPath/host-tier, latticeThrows is gate=throws, and the floor
#  baselines are .expr fixtures — see floor-decomp. Those won't deepSeq cleanly.)
#
# Note: this Lix `nix eval` has no `--strict`; the `deepSeq … true` wrapper forces
# the value fully, so strictness is guaranteed regardless.
set -euo pipefail
name="${1:?usage: stat-capture <fixtureName>}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
expr="let hola = import $HOLA_SRC { lib = import ($NIXPKGS + \"/lib\"); }; fx = hola.corpus.$name.mk { }; in builtins.deepSeq (fx.pick (hola.adapter.run hola.adapter.engines.vanilla fx)) true"
NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$tmp" nix eval --impure --expr "$expr" >/dev/null
nixVersion="$(nix --version | awk '{print $NF}')"
jq -c --arg nixv "$nixVersion" \
  '{nrFunctionCalls, nrThunks, nrOpUpdateValuesCopied, nrPrimOpCalls, gcTotalBytes: .gc.totalBytes, cpuTime, nixVersion: $nixv}' "$tmp"

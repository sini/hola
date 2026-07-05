# class-share-toplevel-pessimal — Arm-C's TERMINAL-plane (pessimal) cost record.
#
# Task 7's `class-share` arm (fleet-stats, MEASUREMENT.md §Arm-C) measured den@s2 at the DECLARATION
# layer (baseline-composition witness): +4.6% overhead, byte-SOUND. Its companion soundness check —
# that the TERMINAL (`system.build.toplevel.drvPath`) stays byte-identical under s2 — was documented as
# an out-of-band `nix eval` whose byte result is recorded in dedup-savings.json (`byteGate.toplevelDrvPath`),
# but whose COST (what s2 costs at the terminal plane) was never pinned. This script pins that cost.
#
# It is the PESSIMAL plane for Arm-C: the terminal is dominated by the derivation-construction storm
# (g6-split: composition is ~5% of the terminal //-storm), so s2's per-host machinery overhead
# (pipe.reads cone-expander + per-sid hostConfigFor) is paid in full while NONE of the cross-host
# sharing s2 targets can manifest in this separate-per-host harness. So this is an OVERHEAD/soundness
# record, NOT a win — there is NO floor. The terminal drvPath is byte-identical (the byte gate), so the
# counter delta is pure machinery overhead on an identical output.
#
# Fold discipline (MEASUREMENT.md §Task 7 amendments): the terminal gate is NOT a fifth canonical arm
# key (the set is locked; a `_`-prefixed manifest entry would be unrunnable by the driver). It is this
# documented script — the first-class, reproducible form of the former out-of-band `nix eval`.
#
# Measurement (MEASUREMENT.md §Counter determinism): for each host, force `toplevel.drvPath` under
# den@pinned AND den@s2 in the SAME out-of-band preamble, ×REPS with STOP-on-diff on the four evaluator
# counters + the drvPath, so the s2−pinned delta is BIT-EXACT within-preamble (the same discipline
# secondaryWitness uses — both operands share a preamble). The pinned-den terminal is re-measured HERE
# (not read from g6-split) precisely so the delta is within-preamble; its drvPath is byte-identical to
# g6-split baseline-toplevel (the byte gate below) and its counters match g6-split within the documented
# ±1-3 out-of-band preamble wobble (baselines/README.md pinNote). Emits facts.json (measured verbatim);
# baselines/README.md's jq generator folds it into dedup-savings.json's class-share.terminalPessimal
# block (delta/fractions jq-derived, nothing hand-typed).

set -euo pipefail

REV="8f84aa62168994714d5dc18459d4c5fe96650239" # nix-config corpus pin (MEASUREMENT.md pin table)
# den@s2 (feat/s2-pipe-reads) — LOCAL-ONLY worktree branch (git+file://, campaign impure-local by design).
S2REF="git+file:///home/sini/Documents/repos/den?ref=feat/s2-pipe-reads&rev=487cc671e87982ad04bca69fb9a5723c85ed22ca"
HOLA_SRC="${HOLA_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPS=2
OUTDIR=""

# host -> channel INPUT name, verbatim from ci/tests/den-fleet-parity.nix (the fleet the doc names).
declare -A CHAN=(
  [bitstream]=nixpkgs-unstable
  [blade]=nixpkgs-master
  [cortex]=nixpkgs-master
)
HOSTS=(bitstream blade cortex)

usage() {
  cat >&2 <<'EOF'
usage: class-share-toplevel-pessimal.sh [--reps N] [--out DIR]
  --reps  repetitions per measured force, STOP-on-diff on the deterministic counters + drvPath (default: 2)
  --out   output dir for facts.json + summary.md (default: a fresh temp dir; NOT committed)
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
  --reps)
    REPS="${2:?}"
    shift 2
    ;;
  --out)
    OUTDIR="${2:?}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "class-share-toplevel-pessimal: unknown flag '$1'" >&2
    usage
    exit 2
    ;;
  esac
done
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || {
  echo "class-share-toplevel-pessimal: --reps must be a positive integer" >&2
  exit 2
}

# The fleet eval is deep; the default stack overflows (same reason the parity gate / fleet-stats use it).
ulimit -s unlimited 2>/dev/null || true

nixVersion="$(nix --version | awk '{print $NF}')"
G6="$HOLA_SRC/ci/bench/baselines/g6-split.json" # the pinned baseline-toplevel drvPath (the byte gate)
OUTDIR="${OUTDIR:-$(mktemp -d)}"
mkdir -p "$OUTDIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixed per-host out-of-band preamble: getFlake the pinned corpus + den@s2, bind an s2-overridden
# nixConfig, and a drvOf helper forcing the terminal drvPath. Both forces (pinned/s2) share THIS preamble
# ⇒ the s2−pinned delta is within-preamble exact. The unused binding (s2/ncS2 for the pinned force) is
# lazy and identical in both exprs, so it cancels in the delta.
preamble() { # $1 host, $2 channelInput
  cat <<EOF
let
  nc = builtins.getFlake "github:sini/nix-config/$REV";
  s2 = builtins.getFlake "$S2REF";
  lib = nc.inputs.$2.lib;
  hola = import $HOLA_SRC { inherit lib; };
  ncS2 = nc // { inputs = nc.inputs // { den = s2; }; };
  drvOf = ncX: (hola.adapter.runDenFleet (l: l)
    (hola.corpus.denFleet.mk { nixConfig = ncX; host = "$1"; channelInput = "$2"; })
  ).config.system.build.toplevel.drvPath;
EOF
}

declare -A FC PO CP TH DRV
det() { jq -c '{nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,nrThunks}' "$1"; }

# measure HOST CHAN MODE — force the terminal drvPath under den@pinned (MODE=pinned ⇒ drvOf nc) or
# den@s2 (MODE=s2 ⇒ drvOf ncS2), ×REPS, STOP-on-diff on the four counters AND the drvPath.
measure() {
  local host="$1" chan="$2" mode="$3" bind
  [[ "$mode" == "pinned" ]] && bind="nc" || bind="ncS2"
  local prev="" prevRep=0 sf drv rep cur
  for rep in $(seq 1 "$REPS"); do
    sf="$tmp/$host-$mode-$rep.json"
    echo "  [$host/$mode] rep $rep/$REPS ..." >&2
    drv="$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$sf" nix eval --impure --raw --expr "$(preamble "$host" "$chan")
in drvOf $bind" 2>"$tmp/$host-$mode-$rep.err")" || {
      echo "class-share-toplevel-pessimal: eval FAILED host=$host mode=$mode rep=$rep" >&2
      tail -8 "$tmp/$host-$mode-$rep.err" >&2
      exit 1
    }
    cur="$(det "$sf")|$drv"
    if [[ -n "$prev" && "$cur" != "$prev" ]]; then
      echo "class-share-toplevel-pessimal: NON-REPRODUCIBLE ($host/$mode) — STOP, do not average." >&2
      echo "  rep$prevRep: $prev" >&2
      echo "  rep$rep:    $cur" >&2
      exit 1
    fi
    prev="$cur"
    prevRep="$rep"
  done
  FC["$host,$mode"]="$(jq -r .nrFunctionCalls "$sf")"
  PO["$host,$mode"]="$(jq -r .nrPrimOpCalls "$sf")"
  CP["$host,$mode"]="$(jq -r .nrOpUpdateValuesCopied "$sf")"
  TH["$host,$mode"]="$(jq -r .nrThunks "$sf")"
  DRV["$host,$mode"]="$drv"
}

echo "class-share-toplevel-pessimal: ${#HOSTS[@]} host(s) × {pinned,s2} terminal × $REPS rep(s) (nix $nixVersion)" >&2
for host in "${HOSTS[@]}"; do
  measure "$host" "${CHAN[$host]}" pinned
  measure "$host" "${CHAN[$host]}" s2
  # ── BYTE GATE — the class-share soundness invariant: overriding den to s2 must NOT move the terminal.
  # pinned drvPath == s2 drvPath == the pinned g6-split baseline-toplevel digest. A move is a BUG, not a win.
  g6drv="$(jq -r --arg h "$host" '.hosts[$h]["baseline-toplevel"].digest' "$G6")"
  [[ "${DRV["$host,pinned"]}" == "${DRV["$host,s2"]}" && "${DRV["$host,s2"]}" == "$g6drv" ]] || {
    echo "class-share-toplevel-pessimal: BYTE GATE FAILED ($host) — terminal drvPath moved under s2." >&2
    echo "  pinned: ${DRV["$host,pinned"]}" >&2
    echo "  s2:     ${DRV["$host,s2"]}" >&2
    echo "  g6:     $g6drv" >&2
    exit 1
  }
  echo "  [$host] byte gate PASS: terminal drvPath byte-identical (pinned == s2 == g6-split baseline-toplevel)" >&2
done

# ── emit FACTS (measured verbatim; README jq derives the s2−pinned delta / fractions / fleet sums) ──
FACTS="$OUTDIR/facts.json"
{
  echo "{"
  echo "  \"nixVersion\": \"$nixVersion\", \"reps\": $REPS,"
  echo "  \"perHost\": {"
  sep=""
  for host in "${HOSTS[@]}"; do
    printf '%s    "%s": { "channel": "%s",\n' "$sep" "$host" "${CHAN[$host]}"
    printf '      "pinned": { "counters": {"nrFunctionCalls":%s,"nrPrimOpCalls":%s,"nrOpUpdateValuesCopied":%s,"nrThunks":%s}, "drvPath": "%s" },\n' \
      "${FC["$host,pinned"]}" "${PO["$host,pinned"]}" "${CP["$host,pinned"]}" "${TH["$host,pinned"]}" "${DRV["$host,pinned"]}"
    printf '      "s2":     { "counters": {"nrFunctionCalls":%s,"nrPrimOpCalls":%s,"nrOpUpdateValuesCopied":%s,"nrThunks":%s}, "drvPath": "%s" } }' \
      "${FC["$host,s2"]}" "${PO["$host,s2"]}" "${CP["$host,s2"]}" "${TH["$host,s2"]}" "${DRV["$host,s2"]}"
    sep=$',\n'
  done
  echo ""
  echo "  }"
  echo "}"
} | jq . >"$FACTS"

# ── summary.md (human) ─────────────────────────────────────────────────────────────────────────────
{
  echo "## class-share-toplevel-pessimal — Arm-C terminal-plane cost (nix $nixVersion, ×$REPS reps, STOP-on-diff)"
  echo
  echo "s2 machinery overhead at the TERMINAL (byte-identical drvPath). Overhead record, NOT a win — no floor."
  echo
  echo "| host | force | nrFunctionCalls | nrPrimOpCalls | //-copies | nrThunks |"
  echo "|---|---|---:|---:|---:|---:|"
  for host in "${HOSTS[@]}"; do
    for mode in pinned s2; do
      printf '| %s | %s | %s | %s | %s | %s |\n' "$host" "$mode" \
        "${FC["$host,$mode"]}" "${PO["$host,$mode"]}" "${CP["$host,$mode"]}" "${TH["$host,$mode"]}"
    done
    printf '| %s | **Δ (s2−pinned)** | %s | %s | %s | %s |\n' "$host" \
      "$((${FC["$host,s2"]} - ${FC["$host,pinned"]}))" "$((${PO["$host,s2"]} - ${PO["$host,pinned"]}))" \
      "$((${CP["$host,s2"]} - ${CP["$host,pinned"]}))" "$((${TH["$host,s2"]} - ${TH["$host,pinned"]}))"
  done
  echo
  echo "FACTS: $FACTS"
} | tee "$OUTDIR/summary.md"

echo >&2
echo "class-share-toplevel-pessimal: wrote $FACTS and $OUTDIR/summary.md" >&2

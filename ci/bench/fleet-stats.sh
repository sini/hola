# fleet-stats — force each fleet host's arms under NIX_SHOW_STATS and emit the per-(host × arm)
# counter/cpu matrix the fleet-eval campaign (MEASUREMENT.md, Tasks 6–9) consumes.
#
# The driver is GENERIC over the arm manifest (ci/bench/arms.json): an arm is an
#   { expr, raw, nixArgs } record forced inside a FIXED preamble that binds
#   `nixConfig hola lib host channelInput cfg` (see build_expr). Adding an arm — including Task 7's
# `rebuild-dedup` / `class-share` — is a manifest edit, never a code edit. Arm keys are validated
# against the canonical set (MEASUREMENT.md §"Canonical arm keys"); an unknown key aborts loudly.
#
# Baked by the app wrapper (ci/apps.nix):
#   HOLA_SRC            — the hola repo root (package-free `import HOLA_SRC { inherit lib; }`)
#   HOLA_FLEET_NIXCONFIG — the ci-pinned nix-config STORE PATH. `builtins.getFlake` reconstitutes it
#                        to a full flake value (.inputs/.outPath/.sourceInfo), the shell-side
#                        equivalent of the parity test's specialArgs-threaded `denFleet.nixConfig`.
#
# Counter convention mirrors gen's perf-bench: cpuTime is the MEDIAN of reps (robust to host speed);
# the deterministic counters (nrFunctionCalls / nrPrimOpCalls / nrOpUpdateValuesCopied — the //-merge
# storm signature — / nrThunks / gc.totalBytes) and the parity digest are taken from the LAST rep. The digest is the
# drvPath string for a terminal arm or the witness-output hash for the composition arm — a per-host,
# per-arm value a downstream soundness gate byte-compares (Task 7).
#
# Results (results.csv + summary.md) are written to a temp dir by default and are NOT committed —
# they are Task 6's baselines. `--out DIR` pins a location.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: fleet-stats [--hosts a,b] [--arms x,y] [--reps N] [--manifest PATH] [--out DIR]
  --hosts     comma-separated fleet hosts (default: bitstream,blade,cortex)
  --arms      comma-separated arm keys   (default: every arm in the manifest)
  --reps      repetitions per cell       (default: 3)
  --manifest  arm manifest JSON          (default: $HOLA_SRC/ci/bench/arms.json)
  --out       output dir for results.csv+summary.md (default: a fresh temp dir; NOT committed)
EOF
}

# host -> channel INPUT name, verbatim from ci/tests/den-fleet-parity.nix (the fleet the doc names).
declare -A CHANNEL=(
  [bitstream]=nixpkgs-unstable
  [blade]=nixpkgs-master
  [cortex]=nixpkgs-master
)
FLEET_DEFAULT=(bitstream blade cortex)

# The locked arm namespace (MEASUREMENT.md). A manifest key outside this set is rejected.
CANONICAL_ARMS=(baseline-composition baseline-toplevel rebuild-dedup class-share)

REPS=3
MANIFEST="${HOLA_SRC:?HOLA_SRC not baked}/ci/bench/arms.json"
OUTDIR=""
HOSTS=()
ARMS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
  --hosts)
    IFS=',' read -r -a HOSTS <<<"${2:?--hosts needs a value}"
    shift 2
    ;;
  --arms)
    IFS=',' read -r -a ARMS <<<"${2:?--arms needs a value}"
    shift 2
    ;;
  --reps)
    REPS="${2:?--reps needs a value}"
    shift 2
    ;;
  --manifest)
    MANIFEST="${2:?--manifest needs a path}"
    shift 2
    ;;
  --out)
    OUTDIR="${2:?--out needs a dir}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "fleet-stats: unknown flag '$1'" >&2
    usage
    exit 2
    ;;
  esac
done

[[ -n "${HOLA_FLEET_NIXCONFIG:-}" ]] || {
  echo "fleet-stats: HOLA_FLEET_NIXCONFIG not set (the app wrapper bakes it)" >&2
  exit 2
}
[[ -f "$MANIFEST" ]] || {
  echo "fleet-stats: manifest not found: $MANIFEST" >&2
  exit 2
}
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || {
  echo "fleet-stats: --reps must be a positive integer (got '$REPS')" >&2
  exit 2
}

# Every arm key must be canonical — reject an unknown/typo'd arm loudly, up front. Underscore-prefixed
# keys (e.g. `_contract`) are manifest metadata, not arms, so they are skipped here and everywhere.
mapfile -t MANIFEST_ARMS < <(jq -r 'keys[] | select(startswith("_") | not)' "$MANIFEST")
for a in "${MANIFEST_ARMS[@]}"; do
  ok=0
  for c in "${CANONICAL_ARMS[@]}"; do [[ "$a" == "$c" ]] && ok=1; done
  [[ $ok -eq 1 ]] || {
    echo "fleet-stats: manifest arm '$a' is not a canonical arm key (${CANONICAL_ARMS[*]})" >&2
    exit 2
  }
done

[[ ${#HOSTS[@]} -gt 0 ]] || HOSTS=("${FLEET_DEFAULT[@]}")
[[ ${#ARMS[@]} -gt 0 ]] || ARMS=("${MANIFEST_ARMS[@]}")

for h in "${HOSTS[@]}"; do
  [[ -n "${CHANNEL[$h]:-}" ]] || {
    echo "fleet-stats: unknown host '$h' (fleet: ${!CHANNEL[*]})" >&2
    exit 2
  }
done
for a in "${ARMS[@]}"; do
  ok=0
  for m in "${MANIFEST_ARMS[@]}"; do [[ "$a" == "$m" ]] && ok=1; done
  [[ $ok -eq 1 ]] || {
    echo "fleet-stats: unknown arm '$a' (manifest: ${MANIFEST_ARMS[*]})" >&2
    exit 2
  }
done

# The fleet eval is deep; the default stack overflows (same reason the parity gate uses it).
ulimit -s unlimited 2>/dev/null || true

nixVersion="$(nix --version | awk '{print $NF}')"
OUTDIR="${OUTDIR:-$(mktemp -d)}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/results.csv"
SUMMARY="$OUTDIR/summary.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

declare -A CPU FCALLS PRIMOP COPIES THUNKS GCB DIG

# The fixed preamble: reconstitute nix-config, doctor=identity (real build), bind cfg. Arm exprs are
# projections of `cfg` (or, for Task 7, self-contained rebuilds that ignore it — cfg stays lazy).
build_expr() {
  local host="$1" chan="$2" armExpr="$3"
  cat <<EOF
let
  nixConfig = builtins.getFlake "$HOLA_FLEET_NIXCONFIG";
  host = "$host";
  channelInput = "$chan";
  lib = nixConfig.inputs.\${channelInput}.lib;
  hola = import $HOLA_SRC { inherit lib; };
  fx = hola.corpus.denFleet.mk { inherit nixConfig host channelInput; };
  cfg = hola.adapter.runDenFleet (l: l) fx;
in
$armExpr
EOF
}

run_cell() {
  local host="$1" arm="$2"
  local chan="${CHANNEL[$host]}"
  local armExpr raw
  armExpr="$(jq -r --arg a "$arm" '.[$a].expr // error("arm \($a): missing expr")' "$MANIFEST")"
  raw="$(jq -r --arg a "$arm" '.[$a].raw // true' "$MANIFEST")"
  local nixArgs=()
  mapfile -t nixArgs < <(jq -r --arg a "$arm" '.[$a].nixArgs // [] | .[]' "$MANIFEST")
  local rawflag=()
  [[ "$raw" == "true" ]] && rawflag=(--raw)

  local full statf out cpus=() rep
  full="$(build_expr "$host" "$chan" "$armExpr")"
  for rep in $(seq 1 "$REPS"); do
    statf="$tmp/$host-$arm-$rep.json"
    echo "  [$host/$arm] rep $rep/$REPS ..." >&2
    out="$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$statf" \
      nix eval --impure ${rawflag[@]+"${rawflag[@]}"} ${nixArgs[@]+"${nixArgs[@]}"} \
      --expr "$full" 2>"$tmp/$host-$arm-$rep.err")" || {
      echo "fleet-stats: eval FAILED host=$host arm=$arm rep=$rep" >&2
      tail -8 "$tmp/$host-$arm-$rep.err" >&2
      exit 1
    }
    cpus+=("$(jq -r .cpuTime "$statf")")
  done

  local mid=$(((REPS + 1) / 2))
  CPU["$host,$arm"]="$(printf '%s\n' "${cpus[@]}" | sort -g | sed -n "${mid}p")"
  FCALLS["$host,$arm"]="$(jq -r '.nrFunctionCalls' "$statf")"
  PRIMOP["$host,$arm"]="$(jq -r '.nrPrimOpCalls' "$statf")"
  COPIES["$host,$arm"]="$(jq -r '.nrOpUpdateValuesCopied' "$statf")"
  THUNKS["$host,$arm"]="$(jq -r '.nrThunks' "$statf")"
  GCB["$host,$arm"]="$(jq -r '.gc.totalBytes // 0' "$statf")"
  # trim surrounding whitespace/quotes: raw arms print the bare value, non-raw print a nix literal.
  out="${out#"${out%%[![:space:]]*}"}"
  out="${out%"${out##*[![:space:]]}"}"
  out="${out#\"}"
  out="${out%\"}"
  DIG["$host,$arm"]="$out"
}

echo "fleet-stats: ${#HOSTS[@]} host(s) × ${#ARMS[@]} arm(s) × $REPS rep(s)  (nix $nixVersion)" >&2
for host in "${HOSTS[@]}"; do
  for arm in "${ARMS[@]}"; do
    run_cell "$host" "$arm"
  done
done

# ── results.csv (long form — one row per host×arm; Task 6 pivots this) ──────────
{
  echo "host,arm,channel,cpu_median_s,nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,nrThunks,gcTotalBytes,digest,reps,nixVersion"
  for host in "${HOSTS[@]}"; do
    for arm in "${ARMS[@]}"; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$host" "$arm" "${CHANNEL[$host]}" \
        "${CPU[$host,$arm]}" "${FCALLS[$host,$arm]}" "${PRIMOP[$host,$arm]}" "${COPIES[$host,$arm]}" \
        "${THUNKS[$host,$arm]}" "${GCB[$host,$arm]}" "${DIG[$host,$arm]}" \
        "$REPS" "$nixVersion"
    done
  done
} >"$CSV"

# ── summary.md (readable matrix; digest truncated, full value is in the CSV) ────
{
  echo "## fleet-stats — per-host × per-arm ($REPS reps, nix $nixVersion)"
  echo
  echo "| host | arm | cpu (s) | nrFunctionCalls | nrPrimOpCalls | //-copies | nrThunks | gc bytes | digest |"
  echo "|---|---|---:|---:|---:|---:|---:|---:|---|"
  for host in "${HOSTS[@]}"; do
    for arm in "${ARMS[@]}"; do
      printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$host" "$arm" "${CPU[$host,$arm]}" "${FCALLS[$host,$arm]}" "${PRIMOP[$host,$arm]}" \
        "${COPIES[$host,$arm]}" "${THUNKS[$host,$arm]}" "${GCB[$host,$arm]}" \
        "${DIG[$host,$arm]:0:16}"
    done
  done
} | tee "$SUMMARY"

echo >&2
echo "fleet-stats: wrote $CSV and $SUMMARY" >&2

# class-share-realization — Task 7b: the SHARED-EVAL, realization-level class-share arm.
#
# Task 7's `class-share` arm (fleet-stats, MEASUREMENT.md §Arm-C) measured den@s2 at the
# DECLARATION layer under a SEPARATE-per-host harness and found +4.6% overhead — an airtight
# scope-mismatch: the class-share win lives in SHARED-process, projection/REALIZATION-level eval,
# which that harness structurally cannot see. This script measures it in that scope: force a class
# ARCHETYPE's projection once, INJECT its byte-identical shared core into a member via fixed-input
# config-merge, and pay only the member's delta.
#
# Class (Option A — recon decision, MEASUREMENT.md §class-share-realization): a 2-member ad-hoc class
# {blade, cortex}, both nixpkgs-master channel, sharing den's module set. Archetype = blade. Projection
# = systemd.units (a co-produced attrset; the prior synth work's other big projection, system.path, is
# NOT class-invariant across these heterogeneous reals — see the systemPathUnsound block — so injecting
# it whole would fail the byte gate). "Per-added-member" at N=2 = the single marginal of adding cortex.
#
# Mechanism (fixed-input config-merge — the prior work's today-usable `shareClassProjection`):
#   sharedKeys = { k | toJSON blade.units.k == toJSON cortex.units.k }   # the byte-identical intersection (oracle)
#   core       = getAttrs sharedKeys blade.units                          # archetype core, forced ONCE
#   injected   = core // removeAttrs cortex.units sharedKeys              # member = core ∪ its own delta
# The BYTE GATE (the pattern's own gate): toJSON injected == toJSON cortex.units — hard fail on mismatch.
# The per-added-member SAVING = reconstruct(cortex full) − inject(cortex delta) = the shared units cortex
# no longer re-realizes (they come from the archetype). HONEST scope: realization-level, shared-process,
# projection-scoped, N=2; NOT a toplevel claim, NOT 1:1 comparable to the synth 96-host 1.89×–4.38×.
#
# Discipline (MEASUREMENT.md §Counter determinism): the four evaluator counters + digests are exact and
# reproduced ×REPS with STOP-on-diff; gcTotalBytes/cpuTime are informational. Emits a FACTS json (measured
# verbatim) to --out/facts.json; ci/bench/baselines/README.md's jq generator shapes it into the committed
# ci/bench/baselines/class-share-realization.json (deltas/fractions computed by jq, nothing hand-typed).

set -euo pipefail

REV="8f84aa62168994714d5dc18459d4c5fe96650239" # nix-config corpus pin (MEASUREMENT.md pin table)
CHAN="nixpkgs-master"                           # blade + cortex channel input
ARCH="blade"                                    # archetype (a real class member)
MEMBER="cortex"                                 # the added member
HOLA_SRC="${HOLA_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPS=2
OUTDIR=""

usage() {
  cat >&2 <<'EOF'
usage: class-share-realization.sh [--reps N] [--out DIR]
  --reps  repetitions per measured force, STOP-on-diff on the deterministic counters (default: 2)
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
    echo "class-share-realization: unknown flag '$1'" >&2
    usage
    exit 2
    ;;
  esac
done
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || {
  echo "class-share-realization: --reps must be a positive integer" >&2
  exit 2
}

# The fleet eval is deep; the default stack overflows (same reason the parity gate / fleet-stats use it).
ulimit -s unlimited 2>/dev/null || true

nixVersion="$(nix --version | awk '{print $NF}')"
OUTDIR="${OUTDIR:-$(mktemp -d)}"
mkdir -p "$OUTDIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SHARED="$tmp/sharedKeys.json"

# Fixed preamble: getFlake the pinned corpus, master-channel lib, hola from HOLA_SRC, cfgOf per host
# (each host is its own real den nixosConfiguration — no cross-host thunk sharing, the honest baseline).
preamble() {
  cat <<EOF
let
  nc = builtins.getFlake "github:sini/nix-config/$REV";
  lib = nc.inputs.$CHAN.lib;
  hola = import $HOLA_SRC { inherit lib; };
  cfgOf = host: hola.adapter.runDenFleet (l: l) (hola.corpus.denFleet.mk { nixConfig = nc; inherit host; channelInput = "$CHAN"; });
  sharedKeys = builtins.fromJSON (builtins.readFile "$SHARED");
EOF
}

# Run a SETUP eval loudly: stderr to a named .err, and on any failure tail it and exit 1 with a named
# message (never a silent set -e death — the counter cells use the same pattern in measure()). Echoes
# the eval's stdout so callers can capture it; the guard runs BEFORE any assignment consumes the output.
setup_eval() {
  local name="$1"
  shift
  local err="$tmp/setup-$name.err" out
  if ! out="$("$@" 2>"$err")"; then
    echo "class-share-realization: setup eval FAILED ($name)" >&2
    tail -8 "$err" >&2
    exit 1
  fi
  printf '%s' "$out"
}

# ── step 1: the shared-core ORACLE ────────────────────────────────────────────────────────────────
# sharedKeys = the byte-identical systemd.units intersection between archetype and member. This forces
# both hosts (setup, not a counter cell); it is the ground truth the byte gate re-asserts and the class
# boundary a real den-hoag build would instead DECLARE structurally. Sorted ⇒ deterministic digest.
echo "class-share-realization: oracle — byte-identical shared systemd.units core ($ARCH ∩ $MEMBER)" >&2
oracleExpr="$(preamble)
  a = (cfgOf \"$ARCH\").config.systemd.units;
  m = (cfgOf \"$MEMBER\").config.systemd.units;
  common = builtins.filter (k: builtins.elem k (builtins.attrNames m)) (builtins.attrNames a);
in builtins.sort builtins.lessThan (builtins.filter (k: builtins.toJSON a.\${k} == builtins.toJSON m.\${k}) common)"
setup_eval oracle nix eval --impure --json --expr "$oracleExpr" >"$SHARED"
archUnits=$(setup_eval archUnits nix eval --impure --raw --expr "$(preamble) in toString (builtins.length (builtins.attrNames (cfgOf \"$ARCH\").config.systemd.units))")
memberUnits=$(setup_eval memberUnits nix eval --impure --raw --expr "$(preamble) in toString (builtins.length (builtins.attrNames (cfgOf \"$MEMBER\").config.systemd.units))")
sharedCount=$(jq 'length' "$SHARED")
sharedDigest=$(jq -c . "$SHARED" | sha256sum | awk '{print $1}')
echo "  archetype($ARCH)=$archUnits units, member($MEMBER)=$memberUnits units, byte-identical shared core=$sharedCount, sharedKeysDigest=$sharedDigest" >&2

# ── step 2: measure a force ×REPS under NIX_SHOW_STATS, STOP-on-diff on the deterministic counters ──
declare -A FC PO CP TH DIG
det() { jq -c '{nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,nrThunks}' "$1"; }
measure() {
  local name="$1" expr="$2" raw="${3:-raw}"
  local prev="" prevRep=0 sf dig rep flag=(--raw)
  [[ "$raw" == "json" ]] && flag=(--json)
  for rep in $(seq 1 "$REPS"); do
    sf="$tmp/$name-$rep.json"
    echo "  [$name] rep $rep/$REPS ..." >&2
    dig=$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$sf" nix eval --impure "${flag[@]}" --expr "$(preamble)
$expr" 2>"$tmp/$name-$rep.err") || {
      echo "class-share-realization: eval FAILED ($name rep $rep)" >&2
      tail -8 "$tmp/$name-$rep.err" >&2
      exit 1
    }
    local cur
    cur="$(det "$sf")"
    if [[ -n "$prev" && "$cur" != "$prev" ]]; then
      echo "class-share-realization: NON-REPRODUCIBLE deterministic counters for '$name' — STOP, do not average." >&2
      echo "  rep$prevRep: $prev" >&2
      echo "  rep$rep: $cur" >&2
      exit 1
    fi
    prev="$cur"
    prevRep="$rep"
  done
  FC[$name]=$(jq -r .nrFunctionCalls "$sf")
  PO[$name]=$(jq -r .nrPrimOpCalls "$sf")
  CP[$name]=$(jq -r .nrOpUpdateValuesCopied "$sf")
  TH[$name]=$(jq -r .nrThunks "$sf")
  DIG[$name]="$dig"
}

# archetype full (blade, all units — forced once, paid in BOTH modes) ; reconstruct member (cortex full,
# vanilla) ; inject member (cortex delta only — the shared core comes from the archetype).
echo "class-share-realization: measuring archetype / reconstruct / inject (×$REPS, STOP-on-diff)" >&2
measure archetype "in builtins.hashString \"sha256\" (builtins.toJSON (cfgOf \"$ARCH\").config.systemd.units)"
measure reconstruct "in builtins.hashString \"sha256\" (builtins.toJSON (cfgOf \"$MEMBER\").config.systemd.units)"
measure inject "in builtins.hashString \"sha256\" (builtins.toJSON (builtins.removeAttrs (cfgOf \"$MEMBER\").config.systemd.units sharedKeys))"

# ── step 3: the BYTE GATE — injected member projection == real member projection (toJSON equality) ──
echo "class-share-realization: byte gate — injected($MEMBER) == real($MEMBER) systemd.units" >&2
gateExpr="$(preamble)
  a = (cfgOf \"$ARCH\").config.systemd.units;
  m = (cfgOf \"$MEMBER\").config.systemd.units;
  core = builtins.intersectAttrs (builtins.listToAttrs (map (k: { name = k; value = 1; }) sharedKeys)) a;
  injected = core // builtins.removeAttrs m sharedKeys;
  injJson = builtins.toJSON injected;
  realJson = builtins.toJSON m;
in { gate = injJson == realJson; injectedDigest = builtins.hashString \"sha256\" injJson; realDigest = builtins.hashString \"sha256\" realJson; coreCount = builtins.length (builtins.attrNames core); }"
gate="$(setup_eval bytegate nix eval --impure --json --expr "$gateExpr")"
[[ "$(jq -r .gate <<<"$gate")" == "true" ]] || {
  echo "class-share-realization: BYTE GATE FAILED — injected != real. $gate" >&2
  exit 1
}
echo "  byte gate PASS: $(jq -c '{gate,coreCount,injectedDigest}' <<<"$gate")" >&2

# ── step 4: systemPathUnsound — the synth work's 4.38× projection is NOT class-invariant here ──────
echo "class-share-realization: system.path class-invariance (expect FALSE for heterogeneous reals)" >&2
syspathExpr="$(preamble)
  a = (cfgOf \"$ARCH\").config.system.path.drvPath;
  m = (cfgOf \"$MEMBER\").config.system.path.drvPath;
in { archetype = a; member = m; classInvariant = a == m; }"
syspath="$(setup_eval syspath nix eval --impure --json --expr "$syspathExpr")"
echo "  $(jq -c '{classInvariant}' <<<"$syspath")" >&2

# ── step 5: realizationPlaneNativeSharing (informational, ×1) — both members' units from ONE `out` ──
# The realization-layer analogue of the keystone's declaration 1.066×: how much does native memoization
# share the REALIZATION layer in one eval? (Prediction: far less than declarations — host-specific.)
echo "class-share-realization: realization-plane native sharing (both members, one shared out, ×1)" >&2
nsf="$tmp/nativeshare.json"
nsExpr="let
  nc = builtins.getFlake \"github:sini/nix-config/$REV\";
  lib = nc.inputs.$CHAN.lib;
  hola = import $HOLA_SRC { inherit lib; };
  raw = import (nc.outPath + \"/flake.nix\");
  out = raw.outputs (nc.inputs // { self = out // { outPath = nc.outPath; inherit (nc) sourceInfo; }; $CHAN = nc.inputs.$CHAN // { lib = nc.inputs.$CHAN.lib; }; });
  unitsOf = host: out.nixosConfigurations.\${host}.config.systemd.units;
in builtins.hashString \"sha256\" (builtins.toJSON [ (unitsOf \"$ARCH\") (unitsOf \"$MEMBER\") ])"
nsdig=$(NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$nsf" setup_eval nativeshare nix eval --impure --raw --expr "$nsExpr")

# ── emit FACTS (measured verbatim; README jq computes deltas/fractions into the committed baseline) ──
FACTS="$OUTDIR/facts.json"
jq -n \
  --arg nixVersion "$nixVersion" --argjson reps "$REPS" \
  --arg rev "$REV" --arg chan "$CHAN" --arg arch "$ARCH" --arg member "$MEMBER" \
  --argjson archUnits "$archUnits" --argjson memberUnits "$memberUnits" \
  --argjson sharedCount "$sharedCount" --arg sharedDigest "$sharedDigest" \
  --argjson byteGate "$gate" --argjson sysPath "$syspath" \
  --arg aFC "${FC[archetype]}" --arg aPO "${PO[archetype]}" --arg aCP "${CP[archetype]}" --arg aTH "${TH[archetype]}" --arg aDIG "${DIG[archetype]}" \
  --arg rFC "${FC[reconstruct]}" --arg rPO "${PO[reconstruct]}" --arg rCP "${CP[reconstruct]}" --arg rTH "${TH[reconstruct]}" --arg rDIG "${DIG[reconstruct]}" \
  --arg iFC "${FC[inject]}" --arg iPO "${PO[inject]}" --arg iCP "${CP[inject]}" --arg iTH "${TH[inject]}" --arg iDIG "${DIG[inject]}" \
  --arg nsFC "$(jq -r .nrFunctionCalls "$nsf")" --arg nsPO "$(jq -r .nrPrimOpCalls "$nsf")" --arg nsCP "$(jq -r .nrOpUpdateValuesCopied "$nsf")" --arg nsTH "$(jq -r .nrThunks "$nsf")" --arg nsDIG "$nsdig" \
  '{ nixVersion:$nixVersion, reps:$reps,
     class: { rev:$rev, channel:$chan, archetype:$arch, member:$member, projection:"systemd.units",
              archetypeUnits:$archUnits, memberUnits:$memberUnits, byteIdenticalShared:$sharedCount, sharedKeysDigest:$sharedDigest },
     byteGate:$byteGate, systemPath:$sysPath,
     counters: {
       archetype:  { units:$archUnits,  counters:{nrFunctionCalls:($aFC|tonumber),nrPrimOpCalls:($aPO|tonumber),nrOpUpdateValuesCopied:($aCP|tonumber),nrThunks:($aTH|tonumber)}, digest:$aDIG },
       reconstruct:{ units:$memberUnits, counters:{nrFunctionCalls:($rFC|tonumber),nrPrimOpCalls:($rPO|tonumber),nrOpUpdateValuesCopied:($rCP|tonumber),nrThunks:($rTH|tonumber)}, digest:$rDIG },
       inject:     { units:($memberUnits-$sharedCount), counters:{nrFunctionCalls:($iFC|tonumber),nrPrimOpCalls:($iPO|tonumber),nrOpUpdateValuesCopied:($iCP|tonumber),nrThunks:($iTH|tonumber)}, digest:$iDIG }
     },
     realizationPlaneNativeShare: { countersInformational:{nrFunctionCalls:($nsFC|tonumber),nrPrimOpCalls:($nsPO|tonumber),nrOpUpdateValuesCopied:($nsCP|tonumber),nrThunks:($nsTH|tonumber)}, digest:$nsDIG } }' \
  >"$FACTS"

# ── summary.md (human) ─────────────────────────────────────────────────────────────────────────────
{
  echo "## class-share-realization — Task 7b (nix $nixVersion, ×$REPS reps, STOP-on-diff)"
  echo
  echo "Class {$ARCH,$MEMBER} @ $CHAN; archetype=$ARCH; projection=systemd.units."
  echo "shared byte-identical core: $sharedCount / $memberUnits member units; byte gate: $(jq -r .byteGate.gate "$FACTS")."
  echo "system.path class-invariant: $(jq -r .systemPath.classInvariant "$FACTS") (false ⇒ whole-leaf injection unsound here)."
  echo
  echo "| force | units | nrFunctionCalls | nrPrimOpCalls | //-copies | nrThunks |"
  echo "|---|---:|---:|---:|---:|---:|"
  for k in archetype reconstruct inject; do
    printf '| %s | %s | %s | %s | %s | %s |\n' "$k" \
      "$(jq -r ".counters.$k.units" "$FACTS")" "${FC[$k]}" "${PO[$k]}" "${CP[$k]}" "${TH[$k]}"
  done
  echo
  echo "per-added-member ($MEMBER) saving = reconstruct − inject:"
  echo "  fcalls $((${FC[reconstruct]} - ${FC[inject]}))  //-copies $((${CP[reconstruct]} - ${CP[inject]}))  thunks $((${TH[reconstruct]} - ${TH[inject]}))"
  echo
  echo "FACTS: $FACTS"
} | tee "$OUTDIR/summary.md"

echo >&2
echo "class-share-realization: wrote $FACTS and $OUTDIR/summary.md" >&2

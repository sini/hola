# fleet-gates — Task 8: turn the fleet-eval campaign's CLAIMS into permanent regression gates.
#
# The campaign (MEASUREMENT.md, Tasks 5-7b) measured two things and pinned them as baselines under
# ci/bench/baselines/: (1) PARITY — the den fleet builds byte-identically on the vendored engine
# (den-fleet-parity), and (2) SAVINGS DON'T ERODE — the G6 composition/terminal split, the Arm-R
# (gen-rebuild) reuse-across-change saving, the Arm-C (den s2) byte-sound overhead record, and the
# Task-7b realization-plane class-share saving. This script re-asserts all of that.
#
# GATE PARTITION (each gate line is labelled with its partition; the partition decides where it can run):
#   [consistency]      Pure JSON arithmetic over the committed baselines + cross-file / dual-site pin
#                      agreement + the pinned FLOORS. No eval — always CI-runnable, seconds. This is the
#                      --quick pre-commit path. Catches a hand-edit, a corrupted counter, a pin drift.
#   [ci-remeasure]     Re-run the arms whose pins are PUBLIC (github:sini/nix-config + den@5df0987 +
#                      both nixpkgs channels + github:sini/gen-rebuild) and compare to the baseline:
#                      DIGESTS always (nix-version-INDEPENDENT — drvPaths / structural sha256s), the 4
#                      deterministic COUNTERS only when the runner's nix == the baseline's pinned nix
#                      (counters are nix-version-DEPENDENT, MEASUREMENT.md §Counter determinism). ~12-18 min.
#   [local-remeasure]  The Arm-C `class-share` s2 arm needs LOCAL den worktree branches (git+file://,
#                      campaign impure-local by design — MEASUREMENT.md §class-share) that a CI runner
#                      cannot fetch. A documented PRE-PUSH LOCAL gate (--local); skipped in CI.
#   [parity]           The headline claim: den-fleet-parity (vanilla == vendored-engine drvPath) +
#                      channel-modules-identity. CI-runnable (public refs); the same eval `nix flake
#                      check` forces, re-asserted here as the parity half of the gate.
#
# FLOORS (rationale pinned next to each; gen ci/README.md policy — update in-PR with a new table, never
# delete a workload to pass): Arm-R saving >= 0.60 of the fleet composition fcalls (measured 0.667; ~6.7pp
# headroom absorbs a future host-count change without masking a real cone-growth regression). Realization
# class-share saving >= 0.008 of reconstruct fcalls (measured ~0.0158; a floor at ~half guards a sign-flip
# or gross regression — the saving is an exact within-driver delta, so it does not noise-flake).
#
# COUNTER CLASSES (binding): only the deterministic evaluator set — nrFunctionCalls, nrPrimOpCalls,
# nrOpUpdateValuesCopied, nrThunks — feeds any exact/floor math. gcTotalBytes and cpuTime NEVER appear in
# a gate (Boehm/machine noise). The exact gates read EXPLICIT counter paths, never a `.counters` glob, so
# an informational key (gcTotalBytesInformational / realizationPlaneNativeShare.countersInformational)
# can never leak into a comparison.
#
# LIFECYCLE: these hola gates are CAMPAIGN SCAFFOLDING. The durable regression home migrates to
# gen-rebuild's own CI when roadmap-A3 productizes the incremental-rebuild mechanism; hola remains the
# measurement lab. Until then this is the permanent gate — see ci/bench/baselines/README.md §Task 8.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: fleet-gates [--quick | --local | --selftest]
  (default)    consistency + [ci-remeasure] re-measurement + [parity]  (~12-18 min; the CI job)
  --quick      [consistency] gates only — pure JSON arithmetic + pins + floors (seconds; pre-commit path)
  --local      default PLUS the [local-remeasure] Arm-C s2 arm (needs local den worktrees; pre-push)
  --selftest   TEETH — corrupt a copy of a baseline (counter, then floor) and prove the gates FAIL
               (never commits a corrupted baseline; the copy lives in a temp dir)
EOF
}

MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --quick)
    MODE="quick"
    shift
    ;;
  --local)
    MODE="local"
    shift
    ;;
  --selftest)
    MODE="selftest"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "fleet-gates: unknown flag '$1'" >&2
    usage
    exit 2
    ;;
  esac
done

[[ -n "${HOLA_SRC:-}" ]] || {
  echo "fleet-gates: HOLA_SRC not set (the app wrapper bakes it)" >&2
  exit 2
}

# The fleet eval is deep; the default stack overflows (same reason the parity gate / fleet-stats use it).
# Baked once here so every child eval (`nix run #fleet-stats`, class-share-realization.sh, `nix eval`)
# inherits the raised limit.
ulimit -s unlimited 2>/dev/null || true

DET=(nrFunctionCalls nrPrimOpCalls nrOpUpdateValuesCopied nrThunks)
DET_JSON="$(printf '%s\n' "${DET[@]}" | jq -R . | jq -s .)" # the deterministic key list as a JSON array
# Preamble sensitivity (baselines pinNote / MEASUREMENT.md §stub provenance): a change to the baked
# HOLA_SRC store path — ANY hola tree edit, e.g. adding this very script — shifts nrOpUpdateValuesCopied /
# nrThunks by ±1-2, while nrFunctionCalls / nrPrimOpCalls and every digest stay preamble-INVARIANT. The
# [consistency] gates compare WITHIN one baseline (same preamble) so they stay exact on all four; the
# [ci-remeasure] gate compares a FRESH run (new HOLA_SRC preamble) to the committed baseline, so it
# exact-matches the invariant pair + the digests (the structural spine) and bands the sensitive pair by ±2
# (the documented ceiling — a shift beyond it is a STOP-and-report finding, not a benign preamble artifact).
INV_JSON='["nrFunctionCalls","nrPrimOpCalls"]'
BAND_JSON='["nrOpUpdateValuesCopied","nrThunks"]'
PREAMBLE_BAND=2
BL_SRC="$HOLA_SRC/ci/bench/baselines" # the committed baselines — selftest copies these out, never edits them
FAILURES=0

# Two-tier counter gate. Version STRINGS do NOT identify evaluator BUILDS: CI's Determinate Nix and the
# baselines' upstream CppNix BOTH print `nix (Nix) 2.34.7`, yet the Determinate evaluator makes a handful
# fewer primop calls on deep evals (MEASURED: nrPrimOpCalls -8 on ~20M-call evals, ~4e-7 relative; fcalls
# / copies / every digest identical). Comparing only the number falsely reported "same evaluator" and
# hard-failed the CI counter gate. So:
#   STRONG form (EXACT): only on the baseline evaluator — HOLA_STRICT_COUNTERS=1, or AUTO when the version
#     string matches the pin AND we are not in CI. Invariant pair exact, preamble-sensitive pair +-2. The
#     pre-push gate that produced/validates the baselines.
#   CI form (RELATIVE BAND): the default and any non-baseline build — every counter within +-0.1% of the
#     baseline. Evaluator-build noise is ~2500x INSIDE the band, while a real O(k^2)-class regression (the
#     bug class this campaign exists to catch) shifts counters by whole factors and blows through it. So CI
#     keeps real teeth on counters WITHOUT coupling to a specific nix build. `.generated.nixVersion` is the
#     pinned version; upstream CppNix prints it as exactly `nix (Nix) <number>`.
BASELINE_NIX="$(jq -r '.generated.nixVersion' "$BL_SRC/g6-split.json")"
EXPECTED_NIX="nix (Nix) $BASELINE_NIX"
RUNNER_NIX="$(nix --version)"
REL_TOL=0.001 # CI counter tier: 0.1% relative band, per counter per cell
STRICT="${HOLA_STRICT_COUNTERS:-auto}"
if [[ "$STRICT" == "auto" ]]; then
  # auto-strict on the baseline evaluator outside CI (the local pre-push gate); band otherwise.
  if [[ "$RUNNER_NIX" == "$EXPECTED_NIX" && "${CI:-}" != "true" ]]; then STRICT=1; else STRICT=0; fi
fi
if [[ "$STRICT" == "1" ]]; then CMODE=strict; else CMODE=ci; fi

# set_baselines DIR — point the consistency gates at a baseline set (DIR of the three JSONs). Normal runs
# use BL_SRC; --selftest points this at a corrupted temp copy.
set_baselines() {
  BL_DIR="$1"
  G6="$BL_DIR/g6-split.json"
  DEDUP="$BL_DIR/dedup-savings.json"
  CSR="$BL_DIR/class-share-realization.json"
}

# report LABEL DESC RC — print a labelled PASS/FAIL line and tally the global FAILURES on a nonzero RC.
report() {
  local label="$1" desc="$2" rc="$3"
  if [[ "$rc" -eq 0 ]]; then
    printf '  PASS  [%-16s] %s\n' "$label" "$desc"
  else
    printf '  FAIL  [%-16s] %s\n' "$label" "$desc"
    FAILURES=$((FAILURES + 1))
  fi
}

# locate the LIVE flake dir (needed only by the re-measurement gates: a nested `nix run` from a /nix/store
# path breaks the ci flake's `../.` self-reference — same constraint as parity-report.sh). Prefer $PWD.
locate_flake() {
  local d
  for d in "$PWD" "$PWD/ci" "$HOLA_SRC/ci"; do
    [[ -f "$d/flake.nix" ]] && {
      printf '%s' "$d"
      return 0
    }
  done
  return 1
}

# ── [consistency] gates — pure JSON arithmetic over the baselines; jq -e is quiet + exits nonzero on false ──

# Cross-FILE pin agreement: the three baselines must name the SAME corpus/den/nixpkgs revs.
g_pins() {
  jq -e -n --slurpfile g6 "$G6" --slurpfile dd "$DEDUP" --slurpfile csr "$CSR" '
    ($g6[0].pins) as $g | ($dd[0].pins) as $d | ($csr[0].pins) as $c
    | ($g["nix-config"] == $d["nix-config"] and $d["nix-config"] == $c["nix-config"])
      and ($g.den == $d["den-baseline"] and $d["den-baseline"] == $c.den)
      and ($g["nixpkgs-master-channel"] == $d["nixpkgs-master-channel"]
           and $d["nixpkgs-master-channel"] == $c["nixpkgs-master-channel"])
      and ($g["nixpkgs-unstable-channel"] == $d["nixpkgs-unstable-channel"])
  ' >/dev/null
}

# Dual-SITE rev pins (README §Fleet-topology edit sites: "bump BOTH sites or NEITHER"): the gen-rebuild
# rev pinned in dedup-savings.json must equal the rev in the rebuild-dedup arm expr AND ci/flake.nix's
# gen-rebuild input; the den-s2 rev in dedup-savings.json must equal the class-share arm expr's rev.
g_dualsite() {
  local ddGenRebuild ddDenS2 armGenRebuild flakeGenRebuild armDenS2
  ddGenRebuild="$(jq -r '.pins["gen-rebuild"]' "$DEDUP")"
  ddDenS2="$(jq -r '.pins["den-s2"]' "$DEDUP")"
  armGenRebuild="$(grep -oE 'gen-rebuild/[0-9a-f]{40}' "$HOLA_SRC/ci/bench/arms.json" | grep -oE '[0-9a-f]{40}' | head -1)"
  flakeGenRebuild="$(grep -oE 'gen-rebuild/[0-9a-f]{40}' "$HOLA_SRC/ci/flake.nix" | grep -oE '[0-9a-f]{40}' | head -1)"
  armDenS2="$(grep -oE 'rev=[0-9a-f]{40}' "$HOLA_SRC/ci/bench/arms.json" | grep -oE '[0-9a-f]{40}' | head -1)"
  [[ -n "$ddGenRebuild" && "$ddGenRebuild" == "$armGenRebuild" && "$ddGenRebuild" == "$flakeGenRebuild" ]] &&
    [[ -n "$ddDenS2" && "$ddDenS2" == "$armDenS2" ]]
}

# Arm-R: savedRecompute == Σ over the SKIPPED hosts of their baseline-composition counters (g6-split);
# savedFractionOfFleetComposition == savedRecompute / fleet baseline-composition; and dedup's per-host
# `pinned` composition counters match g6-split. EXPLICIT counter paths — never gcTotalBytesInformational.
g_armR_consistency() {
  jq -e -n --slurpfile g6 "$G6" --slurpfile dd "$DEDUP" --argjson C "$DET_JSON" '
    ($g6[0]) as $g | ($dd[0]) as $d
    | ($d["rebuild-dedup"].singleHostEdit) as $she
    | ([ $she.untouchedNodes[] | select(. as $n | $g.hosts | has($n)) ]) as $skipped
    | ($C | all(. as $c
        | ($skipped | map($g.hosts[.]["baseline-composition"].counters[$c]) | add)
          == $she.savedRecompute.counters[$c]))
      and ($C | all(. as $c
        | (($she.savedRecompute.counters[$c] / $g.fleet["baseline-composition"].counters[$c])
           - $she.savedFractionOfFleetComposition[$c] | fabs) < 1e-9))
      and ($g.hosts | keys | all(. as $h | $C | all(. as $c
        | $d["class-share"].compositionWitness.perHost[$h].pinned[$c]
          == $g.hosts[$h]["baseline-composition"].counters[$c])))
  ' >/dev/null
}

# Arm-R FLOOR: saving >= 0.60 of the fleet composition fcalls (measured 0.667). Pinned; rationale in header.
g_armR_floor() {
  jq -e -n --slurpfile dd "$DEDUP" '
    ($dd[0]["rebuild-dedup"].singleHostEdit.savedFractionOfFleetComposition.nrFunctionCalls) >= 0.60
  ' >/dev/null
}

# Arm-C byte gates: composition-digest AND terminal-drvPath byte-identical under s2, per host, and the
# recorded baseline/s2 digests match g6-split. A class-share arm that moved either digest is a BUG.
g_armC_bytegate() {
  jq -e -n --slurpfile g6 "$G6" --slurpfile dd "$DEDUP" '
    ($g6[0]) as $g | ($dd[0]["class-share"].byteGate) as $bg
    | ($bg.compositionDigest.identical == true) and ($bg.toplevelDrvPath.identical == true)
      and ($g.hosts | keys | all(. as $h
        | $bg.compositionDigest.perHost[$h].baseline == $g.hosts[$h]["baseline-composition"].digest
          and $bg.compositionDigest.perHost[$h].s2 == $g.hosts[$h]["baseline-composition"].digest
          and $bg.toplevelDrvPath.perHost[$h].baseline == $g.hosts[$h]["baseline-toplevel"].digest
          and $bg.toplevelDrvPath.perHost[$h].s2 == $g.hosts[$h]["baseline-toplevel"].digest))
  ' >/dev/null
}

# Arm-C delta == s2 − pinned per counter (an OVERHEAD record — NO floor, never treated as a win; the
# gate only re-asserts the arithmetic, so a silently-flipped or hand-edited delta is caught).
g_armC_delta() {
  jq -e -n --slurpfile dd "$DEDUP" --argjson C "$DET_JSON" '
    ($dd[0]["class-share"].compositionWitness) as $cw
    | ($cw.perHost | keys | all(. as $h | $C | all(. as $c
        | $cw.perHost[$h].delta[$c] == ($cw.perHost[$h].s2[$c] - $cw.perHost[$h].pinned[$c]))))
      and ($C | all(. as $c | $cw.fleet.delta[$c] == ($cw.fleet.s2[$c] - $cw.fleet.pinned[$c])))
  ' >/dev/null
}

# Task-7b realization class-share: perAddedMemberSaving == reconstruct − inject; fractionOfReconstruct ==
# saving/reconstruct; the pattern's byte gate (injectedDigest == realDigest == the reconstruct digest);
# and the shared-core counts are sane. EXPLICIT paths — never realizationPlaneNativeShare.countersInformational.
g_csr_consistency() {
  jq -e -n --slurpfile csr "$CSR" --argjson C "$DET_JSON" '
    ($csr[0]) as $c | ($c.measurement) as $m
    | ($C | all(. as $k | $m.perAddedMemberSaving.counters[$k]
        == ($m.reconstruct.counters[$k] - $m.inject.counters[$k])))
      and ($C | all(. as $k
        | (($m.perAddedMemberSaving.counters[$k] / $m.reconstruct.counters[$k])
           - $m.perAddedMemberSaving.fractionOfReconstruct[$k] | fabs) < 1e-9))
      and ($c.byteGate.injectedDigest == $c.byteGate.realDigest)
      and ($c.byteGate.realDigest == $m.reconstruct.digest)
      and ($c.byteGate.injectedEqualsReal == true)
      and ($c.byteGate.coreCount == $c.class.sharedCore.byteIdenticalShared)
      and ($c.class.sharedCore.byteIdenticalShared <= $c.class.sharedCore.memberUnits)
  ' >/dev/null
}

# Task-7b FLOOR: realization saving >= 0.008 of reconstruct fcalls (measured ~0.0158). Pinned; header.
g_csr_floor() {
  jq -e -n --slurpfile csr "$CSR" '
    ($csr[0].measurement.perAddedMemberSaving.fractionOfReconstruct.nrFunctionCalls) >= 0.008
  ' >/dev/null
}

# The normal [consistency] sweep: labelled PASS/FAIL to stdout, tally into the global FAILURES.
run_consistency() {
  set_baselines "$1"
  local rc
  g_pins && rc=0 || rc=1
  report consistency "cross-file pin agreement (nix-config / den / nixpkgs)" "$rc"
  g_dualsite && rc=0 || rc=1
  report consistency "dual-site rev pins (gen-rebuild + den-s2 in arms.json / flake.nix)" "$rc"
  g_armR_consistency && rc=0 || rc=1
  report consistency "Arm-R saving = sum of skipped baseline-composition (byte-exact)" "$rc"
  g_armR_floor && rc=0 || rc=1
  report consistency "Arm-R FLOOR: saving >= 0.60 of fleet composition fcalls" "$rc"
  g_armC_bytegate && rc=0 || rc=1
  report consistency "Arm-C byte gates (composition digest + terminal drvPath)" "$rc"
  g_armC_delta && rc=0 || rc=1
  report consistency "Arm-C delta = s2 - pinned (overhead record, no floor)" "$rc"
  g_csr_consistency && rc=0 || rc=1
  report consistency "Task-7b saving arithmetic + byte gate (injected == real)" "$rc"
  g_csr_floor && rc=0 || rc=1
  report consistency "Task-7b FLOOR: saving >= 0.008 of reconstruct fcalls" "$rc"
}

# Silent [consistency] failure count against a (possibly corrupted) baseline set — used only by --selftest.
# A LOCAL counter (no global FAILURES, no subshell variable sharing), echoed to stdout.
count_consistency_failures() {
  set_baselines "$1"
  local n=0
  g_pins || n=$((n + 1))
  g_dualsite || n=$((n + 1))
  g_armR_consistency || n=$((n + 1))
  g_armR_floor || n=$((n + 1))
  g_armC_bytegate || n=$((n + 1))
  g_armC_delta || n=$((n + 1))
  g_csr_consistency || n=$((n + 1))
  g_csr_floor || n=$((n + 1))
  printf '%s' "$n"
}

# ── [ci-remeasure] gates — re-run the public-pinned arms, compare digests (always) + counters (same nix) ──

# results.csv (fleet-stats long form) → { "host|arm": { <4 counters>, digest } }.
csv_cells() {
  jq -R -s '
    split("\n") | map(select(length > 0)) | .[1:] | map(split(","))
    | map({ key: (.[0] + "|" + .[1]),
            value: { nrFunctionCalls: (.[4] | tonumber), nrPrimOpCalls: (.[5] | tonumber),
                     nrOpUpdateValuesCopied: (.[6] | tonumber), nrThunks: (.[7] | tonumber), digest: .[9] } })
    | from_entries' "$1"
}

# diff_counters EXPECTED ACTUAL — both are { cell: { counter: value, … } } maps. Emit one indented
# "cell counter: expected=E actual=A delta=D tol=T" line per cell×counter that VIOLATES the tolerance for
# the current CMODE (strict: invariant pair exact + preamble pair ±PREAMBLE_BAND; ci: every counter within
# ±REL_TOL relative). Empty output ⇒ all within tolerance. The single self-diagnosing comparator for all
# three re-measure arms (the exact numbers make a CI failure actionable — a gate that prints only FAIL is not).
diff_counters() {
  jq -r -n --argjson exp "$1" --argjson act "$2" \
    --argjson INV "$INV_JSON" --argjson BAND "$BAND_JSON" --argjson band "$PREAMBLE_BAND" \
    --arg mode "$CMODE" --argjson reltol "$REL_TOL" '
    [ $exp | keys[] as $cell | ($INV + $BAND)[] as $c
      | ($act[$cell][$c]) as $a | ($exp[$cell][$c]) as $e | ($a - $e) as $d
      | (if $mode == "strict"
           then (if ($INV | index($c)) then ($d != 0) else (($d | fabs) > $band) end)
           else (($d | fabs) > ($e * $reltol)) end) as $bad
      | select($bad)
      | "    \($cell) \($c): expected=\($e) actual=\($a) delta=\($d) tol=\(if $mode == "strict" then (if $INV | index($c) then "exact" else "±\($band)" end) else "±\($reltol * 100)%rel" end)" ]
    | .[]'
}

g_remeasure_baselines() {
  local dir out cells
  dir="$(locate_flake)" || {
    echo "fleet-gates: no live flake dir for re-measurement (run from hola/ci)" >&2
    return 1
  }
  out="$(mktemp -d)"
  (cd "$dir" && nix run ".#fleet-stats" -- --arms baseline-composition,baseline-toplevel \
    --hosts bitstream,blade,cortex --reps 1 --out "$out") >&2 || return 1
  cells="$(csv_cells "$out/results.csv")"
  # digests always (nix-version-independent)
  jq -e -n --slurpfile g6 "$G6" --argjson cells "$cells" '
    ($g6[0]) as $g
    | ($g.hosts | keys | all(. as $h | ["baseline-composition","baseline-toplevel"] | all(. as $arm
        | $cells[$h + "|" + $arm].digest == $g.hosts[$h][$arm].digest)))' >/dev/null || return 1
  # counters gated in BOTH tiers (strict exact on the baseline evaluator / ci ±0.1% relative elsewhere, per
  # CMODE); diff_counters prints a verbose per-counter table on any violation.
  local exp diff
  exp="$(jq -c -n --slurpfile g6 "$G6" '
    ($g6[0].hosts) as $h
    | [ $h | keys[] as $host | ["baseline-composition","baseline-toplevel"][] as $arm
        | { key: ($host + "|" + $arm), value: $h[$host][$arm].counters } ] | from_entries')"
  diff="$(diff_counters "$exp" "$cells")"
  if [[ -n "$diff" ]]; then
    echo "  [ci-remeasure baselines] COUNTER MISMATCH (mode=$CMODE, evaluator '$RUNNER_NIX'):" >&2
    echo "$diff" >&2
    return 1
  fi
  return 0
}

g_remeasure_rebuild() {
  local dir out dig want
  dir="$(locate_flake)" || return 1
  out="$(mktemp -d)"
  (cd "$dir" && nix run ".#fleet-stats" -- --arms rebuild-dedup --hosts bitstream --reps 1 --out "$out") >&2 || return 1
  # the arm's digest is sha256 of the soundness record (structural, nix-version-independent) — the gate.
  dig="$(jq -R -s 'split("\n") | map(select(length > 0)) | .[1] | split(",") | .[9]' "$out/results.csv" | tr -d '"')"
  want="$(jq -r '.["rebuild-dedup"].byteGate.digest' "$DEDUP")"
  [[ -n "$dig" && "$dig" == "$want" ]]
}

g_remeasure_csr() {
  local out facts
  out="$(mktemp -d)"
  bash "$HOLA_SRC/ci/bench/class-share-realization.sh" --out "$out" >&2 || return 1
  facts="$out/facts.json"
  [[ -f "$facts" ]] || return 1
  # the pattern byte gate + all digests (nix-version-independent)
  jq -e -n --slurpfile f "$facts" --slurpfile b "$CSR" '
    ($f[0]) as $F | ($b[0]) as $B
    | ($F.byteGate.gate == true)
      and ($F.byteGate.injectedDigest == $B.byteGate.injectedDigest)
      and ($F.byteGate.realDigest == $B.byteGate.realDigest)
      and ($F.class.sharedKeysDigest == $B.class.sharedCore.sharedKeysDigest)
      and ($F.counters.archetype.digest == $B.measurement.archetype.digest)
      and ($F.counters.reconstruct.digest == $B.measurement.reconstruct.digest)
      and ($F.counters.inject.digest == $B.measurement.inject.digest)' >/dev/null || return 1
  local exp act diff
  exp="$(jq -c -n --slurpfile b "$CSR" '
    ($b[0].measurement) as $m
    | { archetype: $m.archetype.counters, reconstruct: $m.reconstruct.counters, inject: $m.inject.counters }')"
  act="$(jq -c -n --slurpfile f "$facts" '
    ($f[0].counters) as $c
    | { archetype: $c.archetype.counters, reconstruct: $c.reconstruct.counters, inject: $c.inject.counters }')"
  diff="$(diff_counters "$exp" "$act")"
  if [[ -n "$diff" ]]; then
    echo "  [ci-remeasure csr] COUNTER MISMATCH (mode=$CMODE, evaluator '$RUNNER_NIX'):" >&2
    echo "$diff" >&2
    return 1
  fi
  return 0
}

# ── [parity] — the headline claim: den-fleet-parity + channel-modules-identity (vanilla == engine) ──
g_parity() {
  local dir h res
  dir="$(locate_flake)" || return 1
  for h in bitstream blade cortex; do
    res="$(cd "$dir" && nix eval --impure ".#tests.den-fleet-parity.$h.expr")" || return 1
    [[ "$res" == "true" ]] || return 1
  done
  res="$(cd "$dir" && nix eval --impure ".#tests.channel-modules-identity.check.expr")" || return 1
  [[ "$res" == "true" ]]
}

# ── [local-remeasure] — Arm-C s2 arm (LOCAL-ONLY: needs den git+file:// worktrees) ──
g_remeasure_classshare() {
  local dir out cells
  dir="$(locate_flake)" || return 1
  out="$(mktemp -d)"
  (cd "$dir" && nix run ".#fleet-stats" -- --arms class-share --hosts bitstream,blade,cortex --reps 1 --out "$out") >&2 || {
    echo "fleet-gates: class-share re-measure failed — needs the LOCAL den s2 worktree (git+file://)" >&2
    return 1
  }
  cells="$(csv_cells "$out/results.csv")"
  # byte gate: s2 composition digest == the pinned baseline-composition digest, per host (declarations unchanged)
  jq -e -n --slurpfile g6 "$G6" --argjson cells "$cells" '
    ($g6[0]) as $g
    | ($g.hosts | keys | all(. as $h
        | $cells[$h + "|class-share"].digest == $g.hosts[$h]["baseline-composition"].digest))' >/dev/null || return 1
  local exp diff
  exp="$(jq -c -n --slurpfile dd "$DEDUP" '
    ($dd[0]["class-share"].compositionWitness.perHost) as $cw
    | [ $cw | keys[] as $h | { key: ($h + "|class-share"), value: $cw[$h].s2 } ] | from_entries')"
  diff="$(diff_counters "$exp" "$cells")"
  if [[ -n "$diff" ]]; then
    echo "  [local-remeasure class-share] COUNTER MISMATCH (mode=$CMODE, evaluator '$RUNNER_NIX'):" >&2
    echo "$diff" >&2
    return 1
  fi
  return 0
}

# ── [teeth] — prove a corrupted counter AND a corrupted floor each FAIL the [consistency] sweep ──
g_selftest() {
  local tmp failed_counter failed_floor
  tmp="$(mktemp -d)"

  # teeth #1: corrupt a deterministic COUNTER the Arm-R arithmetic depends on (blade composition fcalls).
  cp "$BL_SRC"/*.json "$tmp/"
  jq '.hosts.blade["baseline-composition"].counters.nrFunctionCalls += 1' "$tmp/g6-split.json" >"$tmp/g6.new"
  mv "$tmp/g6.new" "$tmp/g6-split.json"
  failed_counter="$(count_consistency_failures "$tmp")"

  # teeth #2: corrupt the Arm-R FLOOR value below its pin (0.667 -> 0.10 < 0.60).
  cp "$BL_SRC"/*.json "$tmp/"
  jq '.["rebuild-dedup"].singleHostEdit.savedFractionOfFleetComposition.nrFunctionCalls = 0.10' \
    "$tmp/dedup-savings.json" >"$tmp/dd.new"
  mv "$tmp/dd.new" "$tmp/dedup-savings.json"
  failed_floor="$(count_consistency_failures "$tmp")"

  echo "  teeth #1 (corrupt a pinned counter): $failed_counter consistency gate(s) failed (expect >= 1)" >&2
  echo "  teeth #2 (corrupt a pinned floor):   $failed_floor consistency gate(s) failed (expect >= 1)" >&2
  [[ "$failed_counter" -ge 1 && "$failed_floor" -ge 1 ]]
}

# ── dispatch ──────────────────────────────────────────────────────────────────────────────────────────
if [[ "$CMODE" == "strict" ]]; then
  echo "fleet-gates: mode=$MODE  evaluator='$RUNNER_NIX' (== pinned)  counters=EXACT strong-form (invariant exact, preamble pair ±$PREAMBLE_BAND)" >&2
else
  echo "fleet-gates: mode=$MODE  evaluator='$RUNNER_NIX' (pinned '$EXPECTED_NIX')  counters=±0.1% RELATIVE band (cross-build regression tier; set HOLA_STRICT_COUNTERS=1 on the baseline evaluator for exact)" >&2
fi
echo >&2

rc=0

if [[ "$MODE" == "selftest" ]]; then
  echo "== [teeth] selftest — corrupting a copy of the baselines must FAIL the gate ==" >&2
  if g_selftest; then
    echo >&2
    echo "TEETH OK: both a corrupted counter and a corrupted floor failed the consistency sweep." >&2
    exit 0
  else
    echo >&2
    echo "TEETH BROKEN: a corrupted baseline did NOT fail the gate — the gate has no teeth." >&2
    exit 1
  fi
fi

echo "== [consistency] pure JSON arithmetic + pin agreement + floors ==" >&2
run_consistency "$BL_SRC"

if [[ "$MODE" == "full" || "$MODE" == "local" ]]; then
  echo >&2
  echo "== [ci-remeasure] re-run public-pinned arms; digests always, counters when nix matches ==" >&2
  g_remeasure_baselines && rc=0 || rc=1
  report ci-remeasure "baseline-composition + baseline-toplevel (fleet-stats) vs g6-split" "$rc"
  g_remeasure_rebuild && rc=0 || rc=1
  report ci-remeasure "rebuild-dedup soundness digest vs dedup-savings" "$rc"
  g_remeasure_csr && rc=0 || rc=1
  report ci-remeasure "class-share-realization (Task 7b) vs baseline" "$rc"
  echo >&2
  echo "== [parity] den-fleet-parity + channel-modules-identity (vanilla == vendored engine) ==" >&2
  g_parity && rc=0 || rc=1
  report parity "den-fleet-parity bitstream/blade/cortex + channel-modules-identity" "$rc"
fi

if [[ "$MODE" == "local" ]]; then
  echo >&2
  echo "== [local-remeasure] Arm-C s2 arm — LOCAL-ONLY (needs den git+file:// worktrees) ==" >&2
  g_remeasure_classshare && rc=0 || rc=1
  report local-remeasure "class-share s2 composition digest == baseline (byte-sound)" "$rc"
fi

echo >&2
if [[ "$FAILURES" -eq 0 ]]; then
  case "$MODE" in
  quick) echo "ALL GATES PASSED — [consistency] only (--quick). Re-measurement gates NOT run." ;;
  full) echo "ALL GATES PASSED — [consistency] + [ci-remeasure] + [parity]. [local-remeasure] NOT run (--local)." ;;
  local) echo "ALL GATES PASSED — [consistency] + [ci-remeasure] + [parity] + [local-remeasure]." ;;
  esac
  echo "(campaign scaffolding; durable home migrates to gen-rebuild ci at roadmap-A3 — hola stays the lab.)"
  exit 0
else
  echo "GATES FAILED: $FAILURES gate(s). See the FAIL lines above."
  exit 1
fi

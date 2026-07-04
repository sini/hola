# Fleet baselines — G6 composition/terminal split

`g6-split.json` is the measured composition-vs-terminal cost matrix for the den
fleet (bitstream, blade, cortex), per host and fleet-total. It is the pinned
baseline every downstream trust-release claim cites (Tasks 7–9). The measurement
protocol, the entrypoints, and the pinned inputs are specified in
[`../MEASUREMENT.md`](../MEASUREMENT.md); this file records the numbers that
protocol produced and how to reproduce them.

## What the split compares (read this before the numbers)

The two arms are two **non-nested projections of the same `cfg`** (the vanilla
`runDenFleet (l: l)` real build):

- `baseline-composition` — a derivation-free structure walk of the merged option
  tree (`compositionWalk cfg.options`). It **deepSeqs every declared option**,
  including options no build output ever reaches. It runs den's aspect resolution
  and the whole module-system declaration merge, then stops before value/derivation
  realization.
- `baseline-toplevel` — forces `cfg.config.system.build.toplevel.drvPath`. This
  reaches **only the options on the `build.toplevel` cone**, plus the full
  derivation-construction storm.

Neither projection's work is contained in the other. So a ratio like "composition
is 55% of terminal `nrFunctionCalls`" is a comparison of two projections — it is
**NOT** a part/whole share of the terminal's own composition work, and it does
**NOT** mean "composition is 55% of what the terminal spends on composition." The
composition witness even does *more* declaration work than the terminal's on-cone
composition (it walks off-cone options too), yet lands at a minority of terminal
counters because the terminal is dominated by the derivation storm. Reconcile these
figures against each other and against priors; never equate them.

The per-arm framing that *is* a clean subset comparison — used by Task 7's dedup
arms — is the **DELTA** framing: baseline and arm force the identical witness
expression, so `arm − baseline` on that one expression is valid regardless of the
projection's completeness. That is a separate measurement from the split ratio here.

## The split (nix 2.34.7)

Composition / terminal, per **exact-pinned** counter (from `jq '.ratios' g6-split.json`):

| host | nrFunctionCalls | nrPrimOpCalls | //-copies (merge storm) | nrThunks |
|---|---:|---:|---:|---:|
| bitstream | 55.2% | 40% | 13.7% | 46.3% |
| blade | 40.3% | 27.8% | 4.1% | 29.8% |
| cortex | 36.1% | 24.5% | 3.9% | 26.7% |
| **fleet (Σ/Σ)** | **42.5%** | **29.5%** | **5.2%** | **32.4%** |

Informational (gc bytes is NOT exact-pinned — see below; ratio approximate, from the
recorded run, `jq '.ratios.gcTotalBytesInformational'`): composition/terminal gc bytes
= bitstream 38.7%, blade 18.2%, cortex 16.6%, **fleet 21.3%**.

The load-bearing counter is `nrOpUpdateValuesCopied` — the `//`-merge storm.
Fleet-wide, composition is only **5.2%** of the terminal's `//`-storm: ~95% of the
merge cost lives in value/derivation realization, not declaration composition. The
ratio also *shrinks* from bitstream (13.7%) to blade/cortex (~4%) because the
composition `//`-storm is nearly host-invariant (~4.2M copies on every host) while
the terminal storm explodes with the host's derivation closure (30.5M → 101M →
110M). Absolute counters and digests per host×arm are in `g6-split.json`
(`.hosts`, `.fleet`).

The percentages above round `.ratios` from the JSON; regenerate them with:

```sh
jq -r '
  (["host"] + (.ratios.fleet | keys_unsorted)) as $h
  | ($h | @tsv),
    (.ratios.perHost | to_entries[] | [.key] + (.value | to_entries | map(.value*100|.*10|round/10|tostring+"%")) | @tsv),
    (["fleet"] + (.ratios.fleet | to_entries | map(.value*100|.*10|round/10|tostring+"%")) | @tsv)
' ci/bench/baselines/g6-split.json
```

## Prior reconciliation

**(a) The `cortex ≈ 94% derivation-construction` prior.** That figure is a **TIME
profile** of forcing the cortex *terminal* (`hola perf`: cortex's ~36 s eval is 94%
intrinsic derivation construction, single-thread-eval-bound). It is a different
metric on a different projection than this counter split, so **reconcile, do not
equate**. They agree directionally and corroborate each other: cortex composition
is only **3.9%** of the terminal `//`-storm ⇒ ~96% of the terminal's merge work is
outside declaration composition (value/derivation realization), the same regime the
94%-time prior names. The `nrFunctionCalls` ratio reads higher (36.1%) only because
the composition witness traverses all declared options off-cone — counting function
calls the terminal never makes — which is exactly why fcalls and `//`-copies
diverge. There is no contradiction here to investigate: a minority-composition,
derivation-dominated terminal is what both the counter split and the time prior say.

**(b) What this predicts for the dedup arms (Task 7) — prediction, not a claim.**
The composition counters are near host-invariant: `nrFunctionCalls` is
17,634,072 / 17,673,112 / 17,677,224 across bitstream/blade/cortex (within 0.24%),
and the composition `//`-storm is ~4.2M on every host. That near-invariance is the
structural signature of shared class-level declaration work — the precondition the
Plane-2a class-share PoC (`class-share`, Arm C) exploits with its **≈ 60% per-host
composition eval-work collapse** prior. So these baselines *predict* Arm C should
reduce the fleet composition counters (`nrFunctionCalls`/`nrPrimOpCalls`/`nrThunks`,
denominator Σ = 52,984,408 fcalls) toward the single-class cost, up to ~60%, while
the terminal `drvPath` stays byte-identical (Arm C's byte-gate). **Caveat
(MEASUREMENT.md):** the options-tree witness may *under*-report the class-share win —
`hostConfigFor`/`pipe.reads` are config-*resolution* optimizations that live past the
options tree — so the measured Arm-C composition delta could be smaller than 60%;
Task 7 may need the `tryEval`-guarded `cfg.config` secondary witness. For Arm R
(gen-rebuild), the same near-invariance implies a large shared cone: a localized
single-host edit should skip the other hosts' evals (near-zero recompute), while the
pessimal shared-node edit recomputes the whole cone. Task 7 measures all of this as
same-witness deltas and asserts both byte-gates; **do not assume the 60% here.**

## Digests

- `baseline-composition` digest = `sha256` of the merged option tree's **top-level
  attr-name list** — a **coarse, structural** fingerprint. It changes iff the
  declared top-level option set changes, so a resolution-only optimization (Arm C)
  must leave it byte-identical. Per-host values differ (different aspects apply).
- `baseline-toplevel` digest = the **exact** `system.build.toplevel` drvPath.

## What is pinned / not pinned

**Exact-pinned** (deterministic per nix version; **verified reproduced across two
full runs**, bit-for-bit): the four **evaluator** counters — `nrFunctionCalls`,
`nrPrimOpCalls`, `nrOpUpdateValuesCopied`, `nrThunks` — plus both digests, per
host×arm, and the input revs in `.pins`. These are what a regression gate (Task 8)
may exact-match, and what the `.ratios` are computed over.

**Expressly NOT pinned (informational — recorded, never gated):**

- `gcTotalBytes` — the Boehm collector's total-allocation counter is **not
  bit-reproducible**: on the same nix version it drifted **~1e-6 to 1e-5 relative**
  between the two verification runs (e.g. bitstream composition 1,327,464,832 →
  1,327,466,160; blade toplevel 7,317,612,304 → 7,317,605,776 — a few KB on multi-GB
  totals, allocator heap-growth noise, **not** an eval-level nondeterminism: the four
  evaluator counters and both digests reproduced exactly). It is carried in the JSON
  as `…gcTotalBytesInformational` and its ratio under `ratios.gcTotalBytesInformational`,
  labelled approximate. Do **not** gate on it.
- `cpuTime` — machine-dependent (host speed). Recorded in the run's
  `results.csv`/`summary.md`, never committed to this file.

**Task 8 gate policy.** Exact-match gates use **only** the deterministic set — the
four evaluator counters plus both digests. `gcTotalBytes` and `cpuTime` may appear
**only** in FLOOR or RATIO gates with explicit headroom (same policy as the gen
hub's `ci/README.md`), never in an equality check. This partition is fixed in
`../MEASUREMENT.md` §"Counter determinism".

**Pins** (`.pins` in the JSON; corpus revs cross-checked against the fleet's own
`flake.lock`, matching MEASUREMENT.md's pin table): hola harness `5b88004`,
nix-config corpus `8f84aa6`, vendored/unstable-channel nixpkgs `567a49d`, ci nixpkgs
`64c08a7`, master-channel nixpkgs `5e8ca42`, fleet den `5df0987`. The hola harness
rev is HEAD (the fleet-stats driver landed after the doc-time `de5b21d` the pin table
names). The dedup-arm pins (gen-rebuild `7a87691`, den s1 `b3449c8` / s2 `487cc671`)
are Task 7's and are not exercised by this baseline.

## How to refresh

Refresh is a full re-run plus a re-generate. All numbers come from the CSV via `jq`;
nothing is hand-typed.

1. Full-fleet run (writes `results.csv` + `summary.md` to `--out`):

   ```sh
   cd ~/Documents/repos/hola
   nix run ./ci#fleet-stats -- --out /tmp/g6   # defaults: 3 hosts × 2 baseline arms × 3 reps
   ```

1. Regenerate `g6-split.json` from that CSV. `PINS` is the input-rev block (not a
   measured number); every counter/digest/ratio is computed by the `jq` program from
   the CSV. The four evaluator counters are exact-pinned; `gcTotalBytes` is carried
   as `…Informational` (never in `counters`, never gated):

   ```sh
   PINS='{
     "hola":"5b88004ec6bff22c3d585558297015da0d48fb1a",
     "nix-config":"8f84aa62168994714d5dc18459d4c5fe96650239",
     "nixpkgs-vendored-body":"567a49d1913ce81ac6e9582e3553dd90a955875f",
     "nixpkgs-ci":"64c08a7ca051951c8eae34e3e3cb1e202fe36786",
     "nixpkgs-unstable-channel":"567a49d1913ce81ac6e9582e3553dd90a955875f",
     "nixpkgs-master-channel":"5e8ca42db8804dbe70af4d4d3fcd1c71e8409e60",
     "den":"5df0987658d6e44268abba953406480e9f066928",
     "_hola_note":"harness rev (fleet-stats driver + compositionWalk witness) that generated these counters. MEASUREMENT.md'"'"'s pin table lists de5b21d as the doc-time hola rev; the driver landed in the 5 commits after de5b21d, so the baseline is generated at HEAD 5b88004.",
     "_dedup_arm_pins":"gen-rebuild 7a87691 (Arm R) and den s1 b3449c8 / s2 487cc671 (Arm C) are Task 7 pins, unused by the G6 baseline arms — see MEASUREMENT.md pin table."
   }'
   jq -R -s --argjson pins "$PINS" '
     def counters: ["nrFunctionCalls","nrPrimOpCalls","nrOpUpdateValuesCopied","nrThunks"];
     def rat($comp; $term): (counters | map(. as $c | {($c): (($comp[$c]) / ($term[$c]))}) | add);
     ( split("\n") | map(select(length > 0)) | .[1:]
       | map(split(","))
       | map({ host: .[0], arm: .[1], channel: .[2],
               counters: { nrFunctionCalls:(.[4]|tonumber), nrPrimOpCalls:(.[5]|tonumber),
                           nrOpUpdateValuesCopied:(.[6]|tonumber), nrThunks:(.[7]|tonumber) },
               gcTotalBytes:(.[8]|tonumber), digest: .[9], reps:(.[10]|tonumber), nixVersion: .[11] })
     ) as $rows
     | ( $rows | group_by(.host)
         | map({ key: .[0].host,
                 value: ({ channel: .[0].channel }
                         + (map({ (.arm): { counters: .counters,
                                            gcTotalBytesInformational: .gcTotalBytes,
                                            digest: .digest } }) | add)) })
         | from_entries ) as $hosts
     | ( ["baseline-composition","baseline-toplevel"]
         | map(. as $arm
             | { ($arm): (counters
                 | map(. as $c | { ($c): ([ $rows[] | select(.arm == $arm) | .counters[$c] ] | add) })
                 | add) })
         | add ) as $fleetCounters
     | ( ["baseline-composition","baseline-toplevel"]
         | map(. as $arm | { ($arm): ([ $rows[] | select(.arm == $arm) | .gcTotalBytes ] | add) })
         | add ) as $fleetGc
     | ( $hosts | to_entries
         | map({ key: .key,
                 value: rat(.value["baseline-composition"].counters;
                            .value["baseline-toplevel"].counters) })
         | from_entries ) as $hostRatios
     | ( $hosts | to_entries
         | map({ key: .key,
                 value: (.value["baseline-composition"].gcTotalBytesInformational
                         / .value["baseline-toplevel"].gcTotalBytesInformational) })
         | from_entries ) as $hostGcRatios
     | { schema: "hola.g6-split.v1",
         generated: { by: "nix run ./ci#fleet-stats  (defaults: hosts=bitstream,blade,cortex  arms=baseline-composition,baseline-toplevel  reps=3)",
                      from: "results.csv, last-rep values", nixVersion: $rows[0].nixVersion, reps: $rows[0].reps },
         pinNote: "EXACT-pinned (deterministic per nix version, verified reproduced across two full runs): the 4 evaluator counters (nrFunctionCalls, nrPrimOpCalls, nrOpUpdateValuesCopied, nrThunks) + both digests. INFORMATIONAL (recorded, NOT exact-gated): gcTotalBytes — Boehm total-allocation, drifts ~1e-6..1e-5 run-to-run; and cpuTime (machine-dependent, not carried in this file). Ratios are computed over the exact counters; the gc ratio is informational/approximate.",
         framing: "composition and terminal are two NON-NESTED projections of the same cfg: the baseline-composition witness deepSeqs ALL declared options; the baseline-toplevel force reaches only the build.toplevel cone plus the derivation-construction storm. ratios below compare the two projections — they are NOT a part/whole share of the terminal'"'"'s own composition work.",
         digestNote: "baseline-composition digest = sha256 of the merged option tree'"'"'s top-level attr-name list (coarse, structural — changes iff the declared top-level option set changes). baseline-toplevel digest = the exact system.build.toplevel drvPath.",
         pins: $pins, hosts: $hosts, fleet: { counters: $fleetCounters, gcTotalBytesInformational: $fleetGc },
         ratios: { note: "composition / terminal, per EXACT counter; derived from hosts[*] and fleet counters by the generation command — not hand-typed.",
                   perHost: $hostRatios, fleet: rat($fleetCounters["baseline-composition"]; $fleetCounters["baseline-toplevel"]),
                   gcTotalBytesInformational: { note: "gc bytes is NOT exact-pinned (Boehm noise ~1e-6..1e-5 run-to-run); this ratio is approximate, from the recorded run.",
                                                perHost: $hostGcRatios, fleet: ($fleetGc["baseline-composition"] / $fleetGc["baseline-toplevel"]) } } }
   ' /tmp/g6/results.csv > ci/bench/baselines/g6-split.json
   ```

1. Verify: a second `nix run ./ci#fleet-stats` on the same nix version must
   reproduce every **exact-pinned** counter and digest exactly. Diff the two CSVs'
   pinned columns — host, arm, the four evaluator counters, digest (column 9,
   `gcTotalBytes`, is **excluded**: it is informational and drifts):

   ```sh
   diff <(cut -d, -f1,2,5,6,7,8,10 /tmp/g6/results.csv) <(cut -d, -f1,2,5,6,7,8,10 /tmp/g6b/results.csv)
   ```

   If any **exact-pinned** counter or digest differs between two runs on the same
   nix version, that is a finding — **STOP and report it, do not average.** (A
   `gcTotalBytes`-only diff is expected and is not a finding.)

## Threshold-update policy

Same policy as the gen hub's `ci/README.md` §"Updating thresholds / workloads":
counters are deterministic per nix version, so if a legitimate engine/corpus change
shifts a baseline, **update this JSON and the table above in the same PR, citing the
new run output — never delete a workload (host or arm) to make a comparison pass.**
New fleet hosts or arms are added to `ci/bench/arms.json` (arms) / the driver's host
map, then re-baselined here.

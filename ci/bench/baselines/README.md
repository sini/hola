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
94%-time prior names. And because the options witness **over-counts** declaration
work — it walks off-cone options the terminal never merges — the 3.9% composition
share is an **upper bound**, so the ~96% realization residual is a conservative
**lower bound**. The `nrFunctionCalls` ratio reads higher (36.1%) only because
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

1. Full-fleet run (writes `results.csv` + `summary.md` to `--out`). Task 7 added the
   `class-share` / `rebuild-dedup` arms to the manifest, so the driver's DEFAULT arm
   set is now all four — the G6 baseline refresh must name its two arms explicitly:

   ```sh
   cd ~/Documents/repos/hola
   nix run ./ci#fleet-stats -- --arms baseline-composition,baseline-toplevel --out /tmp/g6
   # 3 hosts × 2 baseline arms × 3 reps (default reps)
   ```

   Expected runtime ~5–7 min for the full 3×2×3 default (18 evals); the
   `baseline-toplevel` arm dominates and scales with host size — cortex's is
   ~35 s/rep, bitstream's ~15 s.

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
     "_dedup_arm_pins":"gen-rebuild 7a87691 (Arm R) and den s1 b3449c8 / s2 487cc671 (Arm C) are Task 7 pins, unused by the G6 baseline arms — see MEASUREMENT.md pin table.",
     "_meta":"underscore-prefixed keys in .pins are prose annotations, not revs; consumers skip them."
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
             | { ($arm): {
                   counters: (counters
                     | map(. as $c | { ($c): ([ $rows[] | select(.arm == $arm) | .counters[$c] ] | add) })
                     | add),
                   gcTotalBytesInformational: ([ $rows[] | select(.arm == $arm) | .gcTotalBytes ] | add)
                 } })
         | add ) as $fleet
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
         pins: $pins, hosts: $hosts, fleet: $fleet,
         ratios: { note: "composition / terminal, per EXACT counter; derived from hosts[*] and fleet counters by the generation command — not hand-typed.",
                   perHost: $hostRatios, fleet: rat($fleet["baseline-composition"].counters; $fleet["baseline-toplevel"].counters),
                   gcTotalBytesInformational: { note: "gc bytes is NOT exact-pinned (Boehm noise ~1e-6..1e-5 run-to-run); this ratio is approximate, from the recorded run.",
                                                perHost: $hostGcRatios, fleet: ($fleet["baseline-composition"].gcTotalBytesInformational / $fleet["baseline-toplevel"].gcTotalBytesInformational) } } }
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

**Fleet-topology edit sites (a host/channel addition must touch ALL of these — none
can be silently missed):** (1) `ci/bench/fleet-stats.sh` — the `CHANNEL` host→channel
map AND `FLEET_DEFAULT` (the driver's default host list); (2) the `rebuild-dedup` arm
`expr` in `ci/bench/arms.json` — its own inline `channelOf` map AND `hosts` list (the
arm is self-contained, so it does NOT read the driver map); (3) re-baseline both
`g6-split.json` and `dedup-savings.json` for the new host. Miss (2) and the fleet
graph silently keeps the old host set while the baselines grow — a false pass.

## Dedup savings — Arm R + Arm C (`dedup-savings.json`)

`dedup-savings.json` is the Task-7 companion to `g6-split.json`: the two dedup arms
measured fleet-wide, both **byte-gated**. Read this before the numbers — the two
savings mean very different things.

**Arm R — `rebuild-dedup` (gen-rebuild), what the counter delta MEANS.** This is
**incremental reuse-ACROSS-CHANGE, not a single-eval speedup.** The fleet is modelled
as a gen-rebuild graph (nodes = a shared class-composition producer + the three hosts;
edge `host → shared`; `recompute host` forces the host's real `compositionNames`). A
localized single-host edit recomputes ONLY that host's cone and reuses the rest
byte-for-byte — proven on the real corpus by the oracle `resultEqualsFullRebuild` and a
poisoned-recompute `coneOnlyRecompute`. The **saving** is therefore the work of the
hosts you did NOT re-evaluate: Σ of the *skipped* hosts' `baseline-composition` counters
(from `g6-split.json`). For an edit at bitstream that is blade + cortex ≈ **66.7% of the
fleet composition `nrFunctionCalls`**. gen-rebuild does not beat `O(|cone|)` total work
in one pure eval (v3 minimality verdict); the win only exists because a *prior* store is
reused after a change. The pessimal boundary (a shared-node edit) recomputes everything —
saving 0 — and is recorded honestly. **Cross-plane (do not read Arm R against Arm C):**
that 35,350,336-fcall saving is the SEPARATE-per-host (deploy-time / cross-eval) recompute
of blade + cortex; the Arm-C keystone shows the SAME declaration layer is nearly free to
share WITHIN one eval (18.8M ≈ 1.066× a single host, not the 35.35M naive sum). Different
execution planes, not in tension — Arm R avoids the cross-eval recompute a change repeats
host-by-host, Arm C's keystone measures the in-eval plane native memoization already shares.

**Arm C — `class-share` (den s1/s2), what the counter delta MEANS.** The byte gates PASS
(composition digest AND terminal `toplevel.drvPath` byte-identical under den@s2, all three
hosts) — s2 is a correct resolution-only optimization. But the composition-counter delta
is **positive**: a consistent **~+4.6% s2 machinery overhead** on every host, NOT a win.
The ~60% Plane-2a prior is a cross-host fleet-eval-sharing collapse that this
separate-per-host-eval harness structurally cannot capture; the derivation-free witness
sits at the declaration layer, which native Nix thunk memoization already shares. The
secondary `cfg.config` witness is **informational only** — its `deepSeq` stack-overflows
(uncatchable by `builtins.tryEval`), so it measures work-up-to-a-deterministic-crash;
the delta is stable and agrees with the primary, the absolutes are a crash-prefix. Full
reasoning: `../MEASUREMENT.md` §"Task 7 amendments".

### How to reproduce

The deterministic counters + digests reproduce bit-for-bit per nix version (verified
across two runs, same discipline as `g6-split.json`). Every number is regenerated from
the measured CSV + the pinned `g6-split.json`; nothing is hand-typed.

1. Class-share composition, fleet (s2 override), `results.csv`:

   ```sh
   nix run ./ci#fleet-stats -- --arms class-share --hosts bitstream,blade,cortex --reps 1 --out /tmp/cshare
   ```

1. Class-share terminal byte gate (out-of-band; s2 `toplevel.drvPath` must equal the
   `g6-split.json` `baseline-toplevel` digest per host). One host shown; repeat per host:

   ```sh
   nix eval --impure --raw --expr 'let nc = builtins.getFlake "github:sini/nix-config/8f84aa62168994714d5dc18459d4c5fe96650239"; s2 = builtins.getFlake "git+file:///home/sini/Documents/repos/den?ref=feat/s2-pipe-reads&rev=487cc671e87982ad04bca69fb9a5723c85ed22ca"; lib = nc.inputs.nixpkgs-unstable.lib; hola = import ./. { inherit lib; }; ncS2 = nc // { inputs = nc.inputs // { den = s2; }; }; in (hola.adapter.runDenFleet (l: l) (hola.corpus.denFleet.mk { nixConfig = ncS2; host = "bitstream"; channelInput = "nixpkgs-unstable"; })).config.system.build.toplevel.drvPath'
   ```

1. Rebuild-dedup soundness record + digest (fleet-wide, run once):

   ```sh
   nix run ./ci#fleet-stats -- --arms rebuild-dedup --hosts bitstream --reps 1 --out /tmp/rdedup
   ```

1. Regenerate `dedup-savings.json`. `FACTS` holds the values measured by steps 2–3 (the
   byte-gate drvPaths, the `rebuild-dedup` soundness record + digest, and the secondary
   `cfg.config` counters — recorded verbatim from the evals, not derived). The jq program
   then reads `g6-split.json` (pinned `baseline-composition`) + the class-share CSV (s2
   composition), computes Arm R's saving as Σ of the *skipped* hosts' `baseline-composition`
   counters and Arm C's delta as `s2 − pinned` per counter, and asserts both byte gates
   against `g6-split.json`:

   ```sh
   FACTS='{
     "rebuildDedup": { "digest": "d2dc0fee470d38e1d96b12d22130f7534fafc0d5d7af1091c80fc88822b1bd7d",
       "record": { "editHost": "bitstream", "recomputedCone": ["bitstream"],
         "untouchedNodes": ["blade","cortex","shared"], "resultEqualsFullRebuild": true,
         "coneOnlyRecompute": true, "untouchedReused": true } },
     "classShare": {
       "toplevelS2DrvPath": {
         "bitstream": "/nix/store/70xb6lxavlwvn98zhd9badjmvzq7yznn-nixos-system-bitstream-26.11.20260616.567a49d.drv",
         "blade": "/nix/store/z1j54phnlbgn4sn0nzk7c3fnjwfgs322-nixos-system-blade-26.11.20260622.5e8ca42.drv",
         "cortex": "/nix/store/93da5ba9ahyan0cs0dmp73cpyrlfdvgi-nixos-system-cortex-26.11.20260622.5e8ca42.drv" },
       "secondaryCfgConfig": {
         "bitstream": { "pinned": {"nrFunctionCalls":19840113,"nrPrimOpCalls":6032270,"nrOpUpdateValuesCopied":12586179,"nrThunks":23940301}, "s2": {"nrFunctionCalls":20651047,"nrPrimOpCalls":6156056,"nrOpUpdateValuesCopied":12635184,"nrThunks":24752869} },
         "blade": { "pinned": {"nrFunctionCalls":23979069,"nrPrimOpCalls":8058894,"nrOpUpdateValuesCopied":46453104,"nrThunks":33426022}, "s2": {"nrFunctionCalls":24790553,"nrPrimOpCalls":8183348,"nrOpUpdateValuesCopied":46502131,"nrThunks":34239457} },
         "cortex": { "pinned": {"nrFunctionCalls":23738771,"nrPrimOpCalls":7885919,"nrOpUpdateValuesCopied":44842162,"nrThunks":32807311}, "s2": {"nrFunctionCalls":24550282,"nrPrimOpCalls":8010378,"nrOpUpdateValuesCopied":44891196,"nrThunks":33620825} } } } }'
   PINS='{ "hola":"65179bd (base; the Task-7 dedup wiring lands in the follow-up commits on top, at whose working tree these were measured)",
     "nix-config":"8f84aa62168994714d5dc18459d4c5fe96650239", "den-baseline":"5df0987658d6e44268abba953406480e9f066928",
     "den-s1":"b3449c8ba0325d51a00cd973b8eb104575691dc1", "den-s2":"487cc671e87982ad04bca69fb9a5723c85ed22ca",
     "gen-rebuild":"7a87691f004679668852d53fc130a57bc305e20a", "nixpkgs-unstable-channel":"567a49d1913ce81ac6e9582e3553dd90a955875f",
     "nixpkgs-master-channel":"5e8ca42db8804dbe70af4d4d3fcd1c71e8409e60",
     "_meta":"prose annotations skipped by consumers; den-s1/s2 are local-only worktree branches (git+file://), gen-rebuild is public" }'
   S2=$(jq -R -s 'split("\n")|map(select(length>0))|.[1:]|map(split(","))
     |map({(.[0]):{counters:{nrFunctionCalls:(.[4]|tonumber),nrPrimOpCalls:(.[5]|tonumber),nrOpUpdateValuesCopied:(.[6]|tonumber),nrThunks:(.[7]|tonumber)},digest:.[9]}})|add' /tmp/cshare/results.csv)
   jq -n --slurpfile g6f ci/bench/baselines/g6-split.json --argjson s2 "$S2" --argjson facts "$FACTS" --argjson pins "$PINS" '
     ($g6f[0]) as $g6 | ["nrFunctionCalls","nrPrimOpCalls","nrOpUpdateValuesCopied","nrThunks"] as $C
     | def add2($a;$b): ($C|map({(.):(($a[.])+($b[.]))})|add); def sub2($a;$b): ($C|map({(.):(($a[.])-($b[.]))})|add); def divf($a;$b): ($C|map({(.):(($a[.])/($b[.]))})|add);
       ([$facts.rebuildDedup.record.untouchedNodes[]|select(. as $n|$g6.hosts|has($n))]) as $uh
     | ($uh|map($g6.hosts[.]["baseline-composition"].counters)|reduce .[] as $c ({"nrFunctionCalls":0,"nrPrimOpCalls":0,"nrOpUpdateValuesCopied":0,"nrThunks":0}; add2(.;$c))) as $saved
     | ($g6.fleet["baseline-composition"].counters) as $fleetComp
     | { schema:"hola.dedup-savings.v1", pins:$pins,
         "rebuild-dedup": { byteGate:{ resultEqualsFullRebuild:$facts.rebuildDedup.record.resultEqualsFullRebuild, coneOnlyRecompute:$facts.rebuildDedup.record.coneOnlyRecompute, digest:$facts.rebuildDedup.digest },
           singleHostEdit:{ editHost:$facts.rebuildDedup.record.editHost, recomputedCone:$facts.rebuildDedup.record.recomputedCone, untouchedNodes:$facts.rebuildDedup.record.untouchedNodes,
             savedRecompute:{counters:$saved}, savedFractionOfFleetComposition:divf($saved;$fleetComp) } },
         "class-share": { byteGate:{
             compositionDigest:{ identical:([$g6.hosts|keys[]|($g6.hosts[.]["baseline-composition"].digest==$s2[.].digest)]|all) },
             toplevelDrvPath:{ identical:([$g6.hosts|keys[]|($g6.hosts[.]["baseline-toplevel"].digest==$facts.classShare.toplevelS2DrvPath[.])]|all) } },
           compositionWitness:{ perHost:($g6.hosts|keys|map(. as $h|{($h):{pinned:$g6.hosts[$h]["baseline-composition"].counters,s2:$s2[$h].counters,delta:sub2($s2[$h].counters;$g6.hosts[$h]["baseline-composition"].counters)}})|add) } } }
     ' > ci/bench/baselines/dedup-savings.json
   ```

   The committed `dedup-savings.json` carries the full framing/notes; the snippet above is
   the load-bearing arithmetic (saving = Σ skipped-host baseline composition; delta =
   `s2 − pinned`; both byte gates). Re-run on the same nix version must reproduce every
   deterministic counter + digest exactly — if not, **STOP and report, do not average.**

## class-share-realization — the shared-eval class-share arm (`class-share-realization.json`)

`class-share-realization.json` is the Task-7b companion. It measures the class-share win
in its ACTUAL scope, which Task 7's `class-share` arm (declaration-layer, separate-per-host)
structurally cannot see. Read this before the numbers — the scope is everything.

**What it measures (honest scope).** REALIZATION-level, SHARED-process, projection-scoped,
**N=2-member class**. The instantiate pattern: force a class archetype's projection once,
INJECT its byte-identical shared core into a member (fixed-input config-merge), pay only the
member's delta. On the real 2-member class **{blade, cortex}** (both master channel;
archetype = blade; projection = `systemd.units`), the **212-unit byte-identical shared core**
(76% of cortex's 278 units) injects BYTE-IDENTICALLY and saves the per-added-member (cortex)
**~1.6% `nrFunctionCalls` / ~0.18% `//`-copies**. It is a genuine but SMALL win, and small for
a structural reason: `systemd.units` VALUE realization is only **~2% of a member's eval**; the
host-specific config-resolution SPINE (~98%) dominates and config-merge does not share it across
genuinely-distinct hosts. This is **NOT** a toplevel claim (config-merge reassembles a consumed
projection, never a per-host toplevel) and **NOT** 1:1 comparable to the synth 96-host
1.89×–4.38× priors (`priorContext` in the JSON): those measured HOMOGENEOUS `extendModules`-variant
members sharing the config spine, plus `system.path`'s expensive class-invariant leaf —
`system.path` is NOT class-invariant across these heterogeneous reals (`systemPathUnsound`), so
its big win is unsound here. See [`../MEASUREMENT.md`](../MEASUREMENT.md) §"Task 7b".

**The three forces (nix 2.34.7, ×2 reps, STOP-on-diff):**

| force | units | nrFunctionCalls | //-copies | digest |
|---|---:|---:|---:|---|
| archetype (blade full — forced once, paid in both modes) | 257 | 41,296,723 | 100,738,064 | `f9ac1333…` |
| reconstruct (cortex full — vanilla) | 278 | 46,261,629 | 109,715,177 | `5aefc0b2…` |
| inject (cortex delta — shared core from archetype) | 66 | 45,528,833 | 109,519,756 | `f79a7517…` |
| **per-added-member saving** (reconstruct − inject) | — | **732,796 (1.6%)** | **195,421 (0.18%)** | — |

Byte gate: injected `== ` real (`injectedDigest == realDigest == 5aefc0b2…`, the reconstruct
digest), 212-unit core — a mismatch is an unsound-sharing bug, a hard fail in the script.
`realizationPlaneNativeShare` (informational): both hosts' units from one `out` = 65,193,248
fcalls ≈ **1.49× a single host** (vs the declaration keystone's 1.066×) — the third plane in
MEASUREMENT.md's cross-plane note.

### How to reproduce

The deterministic counters + digests reproduce bit-for-bit per nix version (same discipline as
`g6-split.json`). One self-contained driver measures + byte-gates + emits `facts.json`; the FULL
generator below reshapes it into the committed baseline **byte-for-byte** (every counter, digest,
delta, fraction, and ratio is jq-derived from the measured facts; only `PINS` + `PRIOR` + the prose
framing are literal — same split as the `g6-split.json` / `dedup-savings.json` generators).

1. Measure (runs the oracle, the three forces ×2 with STOP-on-diff, the byte gate, the
   `system.path` soundness check, and the informational native-share probe). Green ⇒ the byte
   gate held and every deterministic counter reproduced across the two reps:

   ```sh
   cd ~/Documents/repos/hola
   bash ci/bench/class-share-realization.sh --out /tmp/csr    # ~5–6 min; ulimit -s unlimited is set inside
   ```

1. Regenerate `class-share-realization.json` from `facts.json`. `PINS` is the input-rev block;
   `PRIOR` is the cited synth context (the ONLY hand-transcribed numbers — same convention as
   `dedup-savings.json` citing the 60% prior); every measured value AND every derived delta /
   fraction / ratio (incl `perAddedMemberSaving`, `projectionCostShare.systemdUnitsFractionOfMemberFcalls`,
   `realizationPlaneNativeShare.savedVsSeparateSumFcalls`) is jq-computed from `facts.json`:

   ```sh
   FACTS=/tmp/csr/facts.json
   PINS='{
     "hola": "8e0b556 (base; the Task-7b follow-up commits — class-share-realization.sh + this baseline + the MEASUREMENT.md/README arm — land ON TOP of this base, at whose working tree these were measured; same convention as g6-split.json _hola_note / dedup-savings.json)",
     "nix-config": "8f84aa62168994714d5dc18459d4c5fe96650239",
     "den": "5df0987658d6e44268abba953406480e9f066928",
     "nixpkgs-master-channel": "5e8ca42db8804dbe70af4d4d3fcd1c71e8409e60",
     "_priorAnalysis": "~/Documents/papers/hola-architecture/analysis/experiments/synthetic-fleet/instantiate-pattern-realization.md — the N=96 synthetic-class instantiate-pattern mechanism + numbers this arm reproduces IN-SCOPE on the real corpus.",
     "_meta": "underscore-prefixed keys are prose annotations / pointers, not revs; consumers skip them. den + master-channel are the pinned baseline fleet (NO s1/s2 override — this arm is a resolution-layer PATTERN measurement, orthogonal to den@s2)."
   }'
   PRIOR='{
     "N": 96,
     "classKind": "synthetic — 96 hostName-VARIANTS of one archetype (extendModules), config spine shared BY CONSTRUCTION",
     "perAddedMemberMarginal": {
       "system.path (leaf, ~42% of cost, mkForce whole-inject)": "4.38× fewer copies / 5.15× faster",
       "systemd.units (co-produced attrset, extendModules+mkForce)": "1.89× fewer copies",
       "systemd.units (fixed-input config-merge)": "2.48× fleet / 3.32× 6-host"
     },
     "whyNot1to1": "Those are HOMOGENEOUS extendModules-VARIANT members sharing the config-resolution spine, and system.path there is class-invariant (all members identical). The real corpus here is HETEROGENEOUS (blade ≠ cortex): each member resolves its OWN full config spine (not shared), and system.path is NOT class-invariant (systemPathUnsound). So the realizable projection (the byte-identical systemd.units core) is CHEAP relative to the unshared spine, and the big system.path win is unsound. Reconciled, not contradicted."
   }'
   jq -n --slurpfile f "$FACTS" --argjson pins "$PINS" --argjson prior "$PRIOR" '
     ($f[0]) as $F
     | ["nrFunctionCalls","nrPrimOpCalls","nrOpUpdateValuesCopied","nrThunks"] as $C
     | ($F.counters.archetype.counters)  as $A
     | ($F.counters.reconstruct.counters) as $R
     | ($F.counters.inject.counters)      as $I
     | ($F.realizationPlaneNativeShare.counters) as $NS
     | def sub2($a;$b): ($C|map({(.):(($a[.])-($b[.]))})|add);
       def frac($a;$b): ($C|map({(.):(($a[.])/($b[.]))})|add);
       (sub2($R;$I)) as $saving
     | { schema: "hola.class-share-realization.v1",
         generated: {
           by: "bash ci/bench/class-share-realization.sh --out DIR  →  jq generator over DIR/facts.json (ci/bench/baselines/README.md §class-share-realization). Deltas/fractions are jq-computed; only priorContext + prose is transcribed.",
           from: "facts.json (measured verbatim: oracle shared-core, archetype/reconstruct/inject counters ×2 STOP-on-diff, byte gate, system.path, realization-plane native share) + PINS + cited priorContext",
           nixVersion: $F.nixVersion, reps: $F.reps
         },
         scope: "REALIZATION-level, SHARED-process, projection-scoped, N=2-member class. NOT a toplevel claim (config-merge reassembles a consumed projection, never a per-host toplevel — the prior-analysis structural limit). NOT 1:1 comparable to the synth 96-host numbers (priorContext) — different N AND heterogeneity.",
         framing: "Task 7'"'"'s `class-share` arm (MEASUREMENT.md §Arm-C) measured den@s2 at the DECLARATION layer under a SEPARATE-per-host harness: +4.6% overhead, because the class-share win is not there. It is HERE: at the REALIZATION layer, force a class archetype'"'"'s projection ONCE and INJECT its byte-identical shared core into a member via fixed-input config-merge, paying only the member'"'"'s delta. On the real 2-member class {blade,cortex} (archetype=blade), the 212-unit byte-identical systemd.units core injects BYTE-IDENTICALLY (byteGate) and saves the per-added-member (cortex) measurement.perAddedMemberSaving (~1.6% fcalls / ~0.18% //-copies). SMALL because systemd.units realization is only ~2% of a member'"'"'s eval (projectionCostShare) — the host-specific config-resolution spine (~98%) dominates and config-merge does NOT share it across genuinely-distinct hosts. The realization layer does NOT enjoy the declaration layer'"'"'s native in-eval sharing (realizationPlaneNativeShare ≈ 1.5× a single host, vs the keystone declaration 1.066×). What den-hoag must make shareable to reach the synth-projected wins is precisely that config-resolution spine.",
         pinNote: "Deterministic evaluator counters + digests are EXACT, reproduced ×\($F.reps) with STOP-on-diff (verify: re-run class-share-realization.sh). gcTotalBytes/cpuTime are informational (omitted). Impure-local getFlake on the pinned corpus (master channel); the ±1–2 preamble sensitivity on nrOpUpdateValuesCopied/nrThunks noted in g6-split.json applies, but perAddedMemberSaving is a within-preamble DELTA (reconstruct − inject in the same driver), so it is exact. realizationPlaneNativeShare is a ×1 informational characterization (NOT gated).",
         pins: $pins,
         class: {
           definition: "Option A (recon decision): a 2-member ad-hoc class {blade, cortex} — both nixpkgs-master channel, sharing den'"'"'s module set. NOT a den-DECLARED class (den classes are nixos/home-manager/user, not host-groups); the shared core is the byte-identical projection intersection, and the archetype is one real member. A genuine near-homogeneous class (Option B — e.g. axon k3s nodes) would likely show a larger shared fraction and is the natural follow-up; Option A suffices for a sound, byte-gated N=2 measurement.",
           members: ["blade","cortex"],
           archetype: $F.class.archetype,
           channel: $F.class.channel,
           projection: $F.class.projection,
           mechanism: "fixed-input config-merge (the prior-analysis today-usable `shareClassProjection`): core = getAttrs sharedKeys archetype.units (forced ONCE); injected member = core // removeAttrs member.units sharedKeys (member pays only its delta; shared values come from the archetype). NO extendModules re-eval — a plain merge on resolved configs.",
           sharedCore: {
             archetypeUnits: $F.class.archetypeUnits,
             memberUnits: $F.class.memberUnits,
             byteIdenticalShared: $F.class.byteIdenticalShared,
             sharedFractionOfMember: ($F.class.byteIdenticalShared / $F.class.memberUnits),
             sharedKeysDigest: $F.class.sharedKeysDigest,
             note: "sharedKeys = { k | toJSON archetype.units.k == toJSON member.units.k } — computed here by a byte-identical-intersection ORACLE (forcing both hosts). A real den-hoag class boundary would supply these STRUCTURALLY; the measurement therefore models the ceiling GIVEN a known boundary. Sorted ⇒ deterministic digest."
           }
         },
         byteGate: {
           oracle: "toJSON injected == toJSON member (the pattern'"'"'s own gate)",
           injectedEqualsReal: $F.byteGate.gate,
           coreCount: $F.byteGate.coreCount,
           injectedDigest: $F.byteGate.injectedDigest,
           realDigest: $F.byteGate.realDigest,
           note: "core // member-delta reassembles the member'"'"'s systemd.units BYTE-IDENTICALLY (injectedDigest == realDigest == the reconstruct digest). A mismatch is a bug (unsound sharing), a hard fail in the script."
         },
         measurement: {
           note: "archetype = archetype.units forced fully (paid in BOTH modes — the archetype is a real deployed host). reconstruct = member.units full (vanilla per-member reconstruction). inject = member DELTA only (removeAttrs member.units sharedKeys — the shared core is reused from the archetype). Injected-class cost = archetype + inject; vanilla-class cost = archetype + reconstruct; the per-added-member SAVING is reconstruct − inject (the member'"'"'s shared units it no longer re-realizes). All ×\($F.reps) reps, deterministic counters STOP-on-diff.",
           archetype: $F.counters.archetype,
           reconstruct: $F.counters.reconstruct,
           inject: $F.counters.inject,
           perAddedMemberSaving: {
             member: $F.class.member,
             note: "reconstruct − inject, per counter; the shared 212-unit realization cortex avoids by reusing the archetype core. Positive = a (small) win.",
             counters: $saving,
             fractionOfReconstruct: frac($saving; $R)
           }
         },
         projectionCostShare: {
           note: "Why the saving is small: the systemd.units VALUE realization is a minority of a member'"'"'s eval; the host-specific config-resolution SPINE dominates. Approximate (assumes ~uniform per-unit cost): (saving.fcalls / byteIdenticalShared) × memberUnits / reconstruct.fcalls.",
           systemdUnitsFractionOfMemberFcalls: (($saving.nrFunctionCalls / $F.class.byteIdenticalShared) * $F.class.memberUnits / $R.nrFunctionCalls),
           configSpineDominates: "≈98% of a member'"'"'s eval is the config-resolution spine (produce the units attrset at all), unshared across genuinely-distinct hosts; only the ~2% unit-value realization is shareable via config-merge, and only the byte-identical fraction of it."
         },
         realizationPlaneNativeShare: {
           note: "INFORMATIONAL (×1). Both members'"'"' systemd.units forced from ONE shared `out` (keystone-style) — the REALIZATION-layer analogue of the declaration keystone (MEASUREMENT.md §Arm-C reconciliation pt2: blade+cortex compositionNames = 1.066× a single host). Answers: does native memoization share REALIZATION in-eval? Far less than declarations.",
           counters: $NS,
           ratioVsSingleHostAvg: ($NS.nrFunctionCalls / (($A.nrFunctionCalls + $R.nrFunctionCalls) / 2)),
           savedVsSeparateSumFcalls: (1 - ($NS.nrFunctionCalls / ($A.nrFunctionCalls + $R.nrFunctionCalls))),
           keystoneDeclarationRatio: 1.066,
           interpretation: "Realization: 2 hosts ≈ 1.5× a single host (25% cheaper than the separate-process sum, from the shared `out`/package closure) — but NOT the declaration layer'"'"'s 1.066×. Host-specific config resolution is not natively shared; declarations are. The third plane in the cross-plane note."
         },
         systemPathUnsound: {
           note: "The synth work'"'"'s biggest projection (system.path, 4.38×) is NOT class-invariant across these heterogeneous reals: blade and cortex have different systemPackages ⇒ different buildEnv drvPath. A whole-leaf mkForce injection would give the member the archetype'"'"'s path ⇒ FAIL the byte gate. So the projection with the big potential win is unsound here; only the cheap systemd.units core is shareable — the heterogeneity double-bind.",
           archetypeDrvPath: $F.systemPath.archetype,
           memberDrvPath: $F.systemPath.member,
           classInvariant: $F.systemPath.classInvariant
         },
         priorContext: { synthFleet: $prior }
       }
   ' > ci/bench/baselines/class-share-realization.json
   ```

   Re-run on the same nix version must reproduce every deterministic counter + digest exactly —
   if not, **STOP and report, do not average.** (`gcTotalBytes`/`cpuTime` are informational and
   are not emitted to `facts.json`.)

**Class-topology note.** This arm's class is the ad-hoc pair {blade, cortex} (master channel).
A host/channel addition to the fleet does not automatically enter this arm — the pair and
archetype are pinned in `ci/bench/class-share-realization.sh` (`ARCH`/`MEMBER`/`CHAN`); a genuine
near-homogeneous class (Option B, e.g. axon nodes) is the natural follow-up and would be a new
archetype/member pin plus a re-baseline.

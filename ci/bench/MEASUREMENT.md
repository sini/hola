# Fleet Measurement Protocol (A1)

This document pins **what** the fleet-eval campaign measures, on **which**
revisions, through **which** entrypoints, before any driver code is written. It
is the source of truth for Tasks 5–9: the entrypoint attr paths, the pinned
inputs, the canonical arm keys, and the two dedup arms with their soundness
gates. Every command block here was smoke-tested at 1-host scale; the observed
output is pasted inline.

The campaign has two questions:

- **G6 split** — the composition/merge-layer cost as a fraction of the per-host
  terminal (and, at fleet scale, of the fleet total). Measured by the
  `baseline-composition` vs `baseline-toplevel` arms.
- **Dedup savings, byte-gated** — how much recompute a localized change avoids.
  Measured by the `rebuild-dedup` (gen-rebuild) and `class-share` (den s1/s2)
  arms.

Measurement style is deterministic evaluator counters from `NIX_SHOW_STATS`
(`nrFunctionCalls`, `nrPrimOpCalls`, `nrOpUpdateValuesCopied` — the `//`-merge
storm signature — and `nrThunks`) plus the parity digests, with `gc.totalBytes` and
`cpuTime` as recorded-only secondaries. All protocol commands are `nix eval` /
`nix-instantiate` shapes compatible with that.

**Counter determinism (measured, 6-cell).** The four evaluator counters above and
both digests are bit-reproducible per nix version — verified **identical across two
full fleet runs** (bitstream/blade/cortex × both baseline arms, nix 2.34.7): they
are the **exact-pinnable** set. `gc.totalBytes` is **recorded-only** — a Boehm
total-allocation number, not an evaluator counter, which drifted **~1e-6..1e-5
relative** between those same two runs (a few KB on multi-GB totals) — so it is
noise-banded and **never exact-gated**; `cpuTime` is likewise recorded-only
(machine-dependent). Baselines therefore exact-pin only the deterministic set;
`gc.totalBytes` / `cpuTime` may feed FLOOR or RATIO gates with explicit headroom,
never an equality check. See `ci/bench/baselines/README.md` §"What is pinned / not
pinned" for the per-cell evidence (the exact drift figures) and the Task 8 gate
policy.

**Same version number ≠ same evaluator build (Task 8 finding).** "Bit-reproducible
per nix version" holds only for the SAME evaluator BUILD. A version STRING does not
identify a build: CI's Determinate Nix and upstream CppNix both print
`nix (Nix) 2.34.7`, yet Determinate's evaluator measured **`nrPrimOpCalls` −8** on
blade/cortex `baseline-toplevel` and all Task-7b forces (~4e-7 relative; `nrFunctionCalls`
/ `nrOpUpdateValuesCopied` / every digest identical). So an EXACT counter gate is
**same-build-only** — `fleet-gates.sh` runs it (strong form) solely on the baseline
evaluator (`HOLA_STRICT_COUNTERS`, auto outside CI). CROSS-BUILD regression detection
uses a **relative band** (±0.1%) that swallows build-level counter noise but not a
real O(k²) blowup. Digests + the byte gate are the cross-build structural spine and
gate everywhere. Details: `ci/bench/baselines/README.md` §Task 8.

## Pinned revisions

| Input | Rev | Role |
|-------|-----|------|
| hola | `de5b21db37de50071ce42902faeb7457ec2cc6a8` | this repo (`main`), the harness |
| nix-config (ci/flake.lock) | `8f84aa62168994714d5dc18459d4c5fe96650239` | the fleet corpus source (`github:sini/nix-config`) |
| nixpkgs — vendored body source | `567a49d1913ce81ac6e9582e3553dd90a955875f` | `nixpkgs-unstable`; `lib/engine/vendor/modules.nix` byte-matches this (and `nixpkgs-master` below) — the `channel-modules-identity` gate |
| nixpkgs — ci `nixpkgs` (bench `NIXPKGS`) | `64c08a7ca051951c8eae34e3e3cb1e202fe36786` | package-free `import (NIXPKGS + "/lib")` + the H1 floor in `ci/apps.nix` |
| nixpkgs-unstable (fleet channel) | `567a49d1913ce81ac6e9582e3553dd90a955875f` | bitstream's channel (`nc.inputs.nixpkgs-unstable`) |
| nixpkgs-master (fleet channel) | `5e8ca42db8804dbe70af4d4d3fcd1c71e8409e60` | blade + cortex channel (`nc.inputs.nixpkgs-master`) |
| den — pinned by the fleet | `5df0987658d6e44268abba953406480e9f066928` | `nc.inputs.den`; the baseline fleet's den |
| gen-rebuild (Arm R) | `7a87691f004679668852d53fc130a57bc305e20a` | `github:sini/gen-rebuild` `main`; **not** in the gen hub — a new flake input |
| den `feat/s1-per-sid-hostconfig` (Arm C) | `b3449c8ba0325d51a00cd973b8eb104575691dc1` | per-sid lazy `hostConfigFor` |
| den `feat/s2-pipe-reads` (Arm C) | `487cc671e87982ad04bca69fb9a5723c85ed22ca` | pipe.reads cone-expander; **superset of s1** |

Arm-C viability rests on one relation: the fleet's den (`5df0987`) is an
**ancestor** of both s1 and s2, so overriding `nc.inputs.den` to s1/s2 adds only
the class-share commits on top of exactly what the fleet already pins — a forward
superset, not a rebase.

## Harness map

### What already EXISTS (do not rebuild)

- `corpus.denFleet.mk { nixConfig, host, channelInput }` (`lib/corpus/den-fleet.nix`)
  — the fleet fixture. `channelInput` names the nixpkgs INPUT to doctor
  (`"nixpkgs-unstable"` | `"nixpkgs-master"`), distinct from den's channel name.
- `adapter.runDenFleet doctor fx` (`lib/adapter.nix`) — the fleet re-entry:
  re-invokes nix-config's raw `flake.nix` outputs with the host's channel input's
  `.lib` replaced by `doctor chan.lib` and the lazy `self`-knot supplying
  `outPath`/`sourceInfo`. `doctor = (l: l)` (identity) ⇒ the host's REAL build;
  `doctor = adapter.fleetEngineLib` ⇒ the host's build on the vendored engine
  modules. Returns `out.nixosConfigurations.<host>` (a full NixOS eval result:
  `{ config, options, graph, pkgs, extendModules, … }`).
- `parity.drvPathGate { a, b }` (`lib/parity.nix`) — reads
  `.config.system.build.toplevel.drvPath` on both and byte-compares. This is the
  terminal entrypoint used by the parity gate.
- `ci/tests/den-fleet-parity.nix` — the byte-parity gate: vanilla (`l: l`) vs
  engine (`fleetEngineLib`) drvPath equality for bitstream / blade / cortex.
  CI-green at `de5b21d` (see the E2b commits). Runs via nix-unit and needs a large
  stack — `ulimit -s unlimited` before `nix-unit --flake .#tests.den-fleet-parity`
  (the fleet eval is deep; the default stack overflows).
- The bench scripts (`ci/bench/{stat-capture,floor-decomp,scaling-curve}.sh`,
  wired as apps in `ci/apps.nix` via `mkBench`, which bakes `HOLA_SRC` +
  `NIXPKGS`). These operate on the **VALUE / floor tier** only —
  `hola.corpus.<name>.mk {}` fixtures forced under `NIX_SHOW_STATS`. They do
  **not** reach the fleet: the fleet needs `denFleet.nixConfig` (the nix-config
  flake input with `.inputs`/`.outPath`), which is threaded via `specialArgs`
  inside the ci flake and is absent from a bare `nix eval --expr`. Their
  `NIX_SHOW_STATS` + `jq` capture pattern is the model to reuse.

### What A1 ADDS (specced here, built later)

- **`baseline-composition` witness** — a derivation-free force of the merged
  option tree (spec below). Task 5 adds it as an adapter/driver helper.
- **A fleet stat-capture driver** — forces `baseline-composition` and
  `baseline-toplevel` per host under `NIX_SHOW_STATS`, threading
  `denFleet.nixConfig` from `specialArgs` (or `builtins.getFlake` for the
  standalone smoke recipe below). Task 5. This is the fleet analogue of
  `stat-capture.sh`; the existing script's job (value-tier fixtures) is not
  duplicated.
- **gen-rebuild flake input + Arm R fleet-graph wiring** — Task 7.
- **A `runDenFleet` twin with `nc.inputs.den` overridden to s2** — Arm C. Task 7.

## Entrypoints (exact attr paths)

Both entrypoints are projections of the SAME `cfg = runDenFleet (l: l) fx`
(vanilla / real build). The doctor is identity; the arms differ only in which
value they force.

### `baseline-toplevel` — the per-host terminal (EXISTS)

```
(adapter.runDenFleet (l: l) fx).config.system.build.toplevel.drvPath
```

Forcing the drvPath forces the module merge PLUS the full input-derivation
closure — composition + the derivation-construction storm. This is the terminal
the parity gate already reads.

### `baseline-composition` — the merge layer (A1 ADDS, Task 5)

`den's resolved pre-terminal structure`, operationalized as a **structure walk of
the merged option tree**: force the attribute-name tree of `cfg.options`, pruning
option/type nodes (`_type`) and derivations (`type == "derivation"`) at WHNF so
no leaf value and no derivation drvPath is ever forced.

```nix
walk = x:
  if !(builtins.isAttrs x) then null
  else if (x._type or null) != null then null        # stop AT each option node
  else if (x.type or null) == "derivation" then null # never force a drvPath
  else builtins.deepSeq (builtins.map walk (builtins.attrValues x)) (builtins.attrNames x);

compositionWitness = cfg: builtins.deepSeq (walk cfg.options) true;
```

Why `cfg.options` and not `cfg.config`: assembling the option tree runs den's
aspect resolution and the whole module-system declaration merge (which modules
apply, their option surface), which IS the composition/merge layer — but it stops
before value realization, so it is derivation-free and **completes
deterministically**. Walking `cfg.config` instead does NOT terminate cleanly: the
merged config tree contains throwing accessors — den/agenix rekey secrets throw
`Accessing the secrets derivation is only possible when storageMode is set to "derivation"`, and structured systemd/quirk values throw on coercion. A
`cfg.config` deepSeq therefore measures only "work up to the first throw," which
is non-deterministic as a baseline. The options walk avoids all of these.

Note the witness is derivation-free but NOT a work-subset of `baseline-toplevel`:
it deepSeqs EVERY declared option (including options no build output ever reaches),
whereas forcing `toplevel.drvPath` only touches the options on the `build.toplevel`
cone. The two are non-nested projections of the same `cfg` — the G6-split ratio
below compares them, it does not decompose one into the other.

> Concern for Task 6/7: the class-share win (Arm C) is a config-RESOLUTION
> optimization (`hostConfigFor`, pipe.reads); the options-tree witness may
> under-report it. This is acceptable because every arm is measured as a DELTA on
> the identical witness/force (baseline vs arm force the exact same expression),
> so the delta is valid regardless of completeness. If the options witness shows
> a negligible Arm-C delta, Task 7 should add a tryEval-guarded `cfg.config` walk
> as a secondary witness (both arms hit the same deterministic throw point, so the
> config-work delta is still comparable).

## Canonical arm keys (locked — later tasks use verbatim)

- `baseline-composition`
- `baseline-toplevel`
- `rebuild-dedup`
- `class-share`

## The arms

### `baseline-composition` + `baseline-toplevel` — the G6 split

Force `compositionWitness cfg` and `cfg.…toplevel.drvPath` for each host, capture
`NIX_SHOW_STATS`, and report composition as a fraction of terminal. Per host the
split is composition/terminal on each counter; at fleet scale it is
Σ-composition / Σ-terminal. The load-bearing counter is `nrOpUpdateValuesCopied`
(the `//`-merge storm): if composition is a small fraction of the terminal's
`//`-storm, most merge cost lives in value/derivation realization, not
declaration composition.

1-host anchor (bitstream; full stubs below): composition is **55%** of terminal
`nrFunctionCalls`, **14%** of the `//`-storm, **39%** of `cpuTime`, **38%** of GC
bytes.

Read this ratio as a comparison of two NON-NESTED projections of the same `cfg`,
NOT as a part/whole share of the terminal's own composition work. The composition
witness forces every declared option; the toplevel force reaches only the options
on the `build.toplevel` cone (plus the derivation storm) — neither projection's
work is contained in the other. So "composition ≈ 55% of terminal
`nrFunctionCalls`" does NOT mean "composition is 55% of what the terminal spends on
composition"; it is one derivation-free projection measured against another,
larger, derivation-bearing projection. Reconcile, do not equate — the same caution
the prior `cortex ≈ 94% derivation-construction` figure needs (a time profile, not
a counter-split; expect the framings to differ) applies to this baseline ratio
too. The per-arm DELTA framing (the identical witness expression forced on both
baseline and arm) is unaffected by all of this and remains the valid comparison.
Task 6 formalizes the split across bitstream/blade/cortex.

### `rebuild-dedup` (Arm R) — gen-rebuild

**Source of truth:** `github:sini/gen-rebuild` @ `7a87691` — `build`,
`propagateEager`, `affected`/`affectedSet`, `BuiltCtx` (README + REFERENCE). This
is the owner's "meaningful dedupe with just gen-rebuild today" claim.

**Mechanism.** Model the fleet as a gen-rebuild graph (a gen-graph accessor):
nodes = the fleet hosts plus their shared composition producer(s) (e.g. a
class-level node); an edge `host → shared` means the host depends on the shared
composition. `recompute accessor store id` forces the node's composition witness
and `hashOf` content-hashes it. `build { accessor, recompute, hashOf }` computes
the full store once.

**With vs without dedup:**

- WITHOUT — a full `build` (or a re-`build` after a change): recompute EVERY node.
- WITH — a localized edit fed through `propagateEager ctx { <changedId> = newDecls }`
  (a single host changes) or `override ctx sharedNode newDecls` (the shared base
  changes): recompute only the dependent cone, reuse the rest byte-for-byte.

**The win** is the counter/recompute-count delta between the two: on a cut-heavy
single-host edit, `affected` is `[thatHost]` and the other `N-1` host evals are
skipped; `propagateEager` constructs `O(|AFFECTED| + frontier)` on the expensive
axis. The pessimal boundary (measure it too, honestly): a change to the shared
composition node recomputes the whole dependent cone — dedup saves nothing there.

**The gate (byte).** `propagateEager`'s store is byte-identical to a from-scratch
`build` with the same edit applied — gen-rebuild's 120-seed soundness property,
demonstrated by the shipped example (`resultEqualsFullRebuild = true`). Task 7
re-asserts store equality on the real fleet graph.

**Honest caveat (from the REFERENCE).** This is reuse-ACROSS-CHANGE (incremental
rebuild), NOT a single from-scratch fleet-eval speedup. gen-rebuild does not beat
`O(|cone|)` total work in a pure single eval (the v3 minimality spike verdict).
"Dedupe with gen-rebuild today" means: after a localized edit, only affected hosts
recompute. The arm measures a before→edit→after counter comparison, byte-gated.
**Outcome (§Task 7 amendments):** re-asserted on the real corpus
(`resultEqualsFullRebuild = true`); a single-host edit skips the other hosts —
**66.7% of the fleet composition `nrFunctionCalls`** saved for an edit at bitstream.

**Wiring.** gen-rebuild is standalone (Class B, nixpkgs-lib-free) and is NOT
re-exported by the gen hub — Task 7 adds it as its own flake input.

### `class-share` (Arm C) — den s1/s2

**Source of truth:** den `feat/s2-pipe-reads` @ `487cc671` (superset of
`feat/s1-per-sid-hostconfig` @ `b3449c8b`).

**Mechanism.** Re-run the fleet with `nc.inputs.den` overridden from the pinned
`5df0987` to s2. s1/s2 make den's fx-pipeline share per-sid/class composition work
across hosts of a class instead of recomputing it per host.

**With vs without / the win.** Force `baseline-composition` (and, for the pessimal
check, `baseline-toplevel`) for each host under den@pinned vs den@s2; the win is
the composition-counter reduction. Prior to reconcile against: the Plane-2a PoC's
`≈ 60% per-host composition eval-work collapse at fleet scale` (that PoC lives in
a published gist, not the repo — Task 6/7 reconciles the number, do not assume it).
**Outcome (§Task 7 amendments):** byte-SOUND but the ~60% did NOT reproduce here —
a consistent +4.6% s2 overhead, because the win is a cross-host fleet-eval-sharing
collapse this separate-per-host-eval harness structurally cannot capture.

**The gate (byte).** The terminal must stay byte-identical: overriding den to s1
leaves `toplevel.drvPath` unchanged (verified below — `identical: true`). A
class-share arm that moves the drvPath is a bug, not a win. What s2 *costs* to
force that byte-identical terminal — the pessimal plane, where the derivation
storm dominates and no sharing manifests — is pinned in
`dedup-savings.json` `class-share.terminalPessimal` (see the fold decision below;
measured by `ci/bench/class-share-toplevel-pessimal.sh`, an overhead record, no
floor).

**Viability: VIABLE.** Branches exist as worktrees, fresh (last commit
2026-06-28), s2 ⊃ s1, and the fleet's pinned den (`5df0987`) is an ancestor of
both — so the override is a forward superset with low compatibility risk. The
override evals and is byte-identical at 1-host scale (smoke below). Cost to wire:
a `runDenFleet` twin that sets `nc.inputs.den = <s2 flake>` (Task 7). No refresh /
rebase is required.

## Protocol commands + observed smoke stubs

All four were run at 1-host scale. The self-contained recipe uses
`builtins.getFlake` on the pinned nix-config (impure, reproducible); Task 5's
driver will thread `denFleet.nixConfig` from `specialArgs` instead, forcing the
identical expressions.

> **Stub provenance — illustrative, not authoritative.** These stubs were captured
> at protocol time with the `compositionWitness` recipe and the doc-time harness.
> The **shipped** driver's composition arm instead forces
> `hashString "sha256" (toJSON (compositionNames cfg))` via the baked-store-path
> preamble, so its digest is a sha256 (not `true`) and its counters differ by 1–2
> from these stubs (e.g. composition `//`-copies 4169338→4169336; toplevel
> `nrPrimOpCalls` 12237806→12237805, `//`-copies 30515568→30515566).
> `ci/bench/baselines/g6-split.json` is authoritative for exact values; do not
> re-run these stubs.

Preamble common to the fleet forces:

```nix
let
  nixConfig = builtins.getFlake "github:sini/nix-config/8f84aa62168994714d5dc18459d4c5fe96650239";
  lib  = nixConfig.inputs.nixpkgs-unstable.lib;
  hola = import ./. { inherit lib; };                       # hola repo root
  fx   = hola.corpus.denFleet.mk {
           inherit nixConfig;
           host = "bitstream"; channelInput = "nixpkgs-unstable";
         };
  cfg  = hola.adapter.runDenFleet (l: l) fx;                # vanilla / real build
in …
```

### `baseline-toplevel`

```sh
NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=stats.json \
  nix eval --impure --raw --expr '<preamble> in cfg.config.system.build.toplevel.drvPath'
jq -c '{nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,cpuTime,gcBytes:.gc.totalBytes}' stats.json
```

Observed (bitstream, ~12.5 s wall):

```
/nix/store/70xb6lxavlwvn98zhd9badjmvzq7yznn-nixos-system-bitstream-26.11.20260616.567a49d.drv
{"nrFunctionCalls":31945508,"nrPrimOpCalls":12237806,"nrOpUpdateValuesCopied":30515568,"cpuTime":14.21,"gcBytes":3431063232}
```

### `baseline-composition`

```sh
NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=stats.json \
  nix eval --impure --expr '<preamble> in compositionWitness cfg'   # walk as specced above
jq -c '{nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,cpuTime,gcBytes:.gc.totalBytes}' stats.json
```

Observed (bitstream, exit 0, no throw, result `true`):

```
true
{"nrFunctionCalls":17634072,"nrPrimOpCalls":4897429,"nrOpUpdateValuesCopied":4169338,"cpuTime":5.61,"gcBytes":1321000000}
```

### `rebuild-dedup` (Arm R mechanism smoke)

The gen-rebuild mechanism is proven runnable today by its shipped B demo (a small
synthetic fleet — gateway + net + 3 hosts — with an override that recomputes only
the changed host's cone):

```sh
cd ~/Documents/repos/gen-rebuild && nix eval -f examples/dag
```

Observed (dedup thesis holds — full-rebuild equality + cone-only recompute):

```
{ cleanStore = { gw = 47; h1 = 11; h2 = 12; h3 = 24; net = 10; };
  overrideStore = { gw = 245; h1 = 110; h2 = 12; h3 = 123; net = 10; };
  recomputedCone = [ "gw" "h1" "h3" ]; untouchedNodes = [ "h2" "net" ];
  coneOnlyRecompute = true; untouchedReused = true;
  resultEqualsFullRebuild = true;        # the byte-gate
  poisonIsReal = true; cycleIsLocatedBlame = true; }
```

Task 7 replaces the synthetic node values with per-host `compositionWitness`
hashes; the demo confirms the `build` / `override` / `affected` /
`resultEqualsFullRebuild` surface the arm needs.

### `class-share` (Arm C viability + byte gate)

Both den branches (`feat/s1-per-sid-hostconfig`, `feat/s2-pipe-reads`) are
LOCAL-ONLY — held worktree branches, pushed to no remote (verified absent on
origin/sini/vic) — so this campaign is impure-local BY DESIGN: `getFlake` +
`--impure` against local checkouts (`git+file://…`). Task 7 must NOT expect a
fetchable ref; if the branches ever publish, swap the `git+file://` ref for a
pinned `github:` ref.

Override `nc.inputs.den` to s1 and byte-compare the terminal:

```nix
let
  nixConfig = builtins.getFlake "github:sini/nix-config/8f84aa62168994714d5dc18459d4c5fe96650239";
  denS1 = builtins.getFlake "git+file:///home/sini/Documents/repos/den?ref=feat/s1-per-sid-hostconfig&rev=b3449c8ba0325d51a00cd973b8eb104575691dc1";
  lib   = nixConfig.inputs.nixpkgs-unstable.lib;
  hola  = import ./. { inherit lib; };
  ncPrime = nixConfig // { inputs = nixConfig.inputs // { den = denS1; }; };
  drvOf = nc: (hola.adapter.runDenFleet (l: l)
                (hola.corpus.denFleet.mk { nixConfig = nc; host = "bitstream"; channelInput = "nixpkgs-unstable"; })
              ).config.system.build.toplevel.drvPath;
in { base = drvOf nixConfig; s1 = drvOf ncPrime; identical = drvOf nixConfig == drvOf ncPrime; }
```

Observed (byte-identical — the class-share soundness gate passes):

```
{ "base": "/nix/store/70xb6lxavlwvn98zhd9badjmvzq7yznn-nixos-system-bitstream-26.11.20260616.567a49d.drv",
  "s1":   "/nix/store/70xb6lxavlwvn98zhd9badjmvzq7yznn-nixos-system-bitstream-26.11.20260616.567a49d.drv",
  "identical": true }
```

## Handoff to downstream tasks

- **Task 5 (fleet-stats driver):** implement `compositionWitness` (the options
  walk above) and a driver that forces `baseline-composition` + `baseline-toplevel`
  per host under `NIX_SHOW_STATS`, `specialArgs`-threaded `denFleet.nixConfig`. Emit
  one JSON line per (host, arm) with the four counters. Reuse `stat-capture.sh`'s
  capture shape; do not touch the value-tier scripts. First step: confirm the
  options walk completes on blade + cortex (master channel) too — bitstream is
  confirmed here.
- **Task 6 (G6 split baseline):** run both baseline arms across the fleet, report
  composition/terminal per counter, reconcile against the `94%` / `60%` priors.
- **Task 7 (dedup arms):** wire gen-rebuild (`rebuild-dedup`) and the s2 den
  override (`class-share`); measure each as a same-witness DELTA; assert both byte
  gates (`resultEqualsFullRebuild` for R; terminal `identical` for C).
- **Task 8 (regression gates):** the fleet parity gate already exists
  (`ci/tests/den-fleet-parity.nix`); run it with `ulimit -s unlimited`.

## Task 7 amendments (execution findings)

Task 7 built both dedup arms and measured them fleet-wide. Two things the
execution taught that this doc did not pre-state are recorded here; the numbers
live in `ci/bench/baselines/dedup-savings.json` (both byte gates PASS).

### The canonical-key fold (decision)

The canonical set has four keys but the arms map to five sub-measurements. The
fold, now fixed:

- **`class-share` = the composition-WIN measurement** (per-host, driven by
  `fleet-stats`): `compositionNames` under `nc.inputs.den = s2` vs the pinned
  baseline. Its digest column doubles as the *declaration* byte gate (must equal
  the `baseline-composition` digest).
- **The `class-share` TERMINAL byte gate AND its cost** (`toplevel.drvPath` under
  s2 == pinned, plus what s2 *costs* to force it) is a committed, reproducible
  ARTIFACT — the `ci/bench/class-share-toplevel-pessimal.sh` script — NOT a fifth
  canonical key. The fold holds: a `_`-prefixed manifest entry would be skipped by
  the driver (unrunnable via `--arms`, and none exists) and the key set is locked,
  so the terminal gate stays a documented **script** (the first-class form of the
  former out-of-band `nix eval`), whose byte result AND the s2 terminal-plane cost
  are pinned in `dedup-savings.json` (`class-share.terminalPessimal`: s2 − pinned
  per host, a byte-identical-terminal OVERHEAD record — **no floor**, since the
  derivation-storm-dominated terminal pays s2's per-host machinery in full while no
  cross-host sharing manifests). Verified byte-identical on all three hosts, with a
  consistent **+1.3–2.4% fcalls** s2 overhead (bitstream 2.37% / blade 1.49% /
  cortex 1.33%). The `[consistency]` gate `g_armC_terminal_pessimal` re-asserts the
  block's arithmetic + the drvPath byte tie.
- **`rebuild-dedup` is FLEET-WIDE, run at ONE host.** Its arm expr builds the
  whole gen-rebuild fleet graph with a fixed `editHost`, so it is identical for
  every driver `host` binding; running it per-host would triple the work for the
  same result. Run it `--hosts bitstream --reps 1`. Its measured counters are the
  harness eval cost (informational); its **digest** is the soundness-record hash
  (the gate), and its **saving** is arithmetic on the Task-6 baseline (below), not
  a per-cell counter.

Consequence: adding these two arms changed the driver's DEFAULT arm set (all
non-`_` manifest keys), so the G6-baseline refresh now passes explicit
`--arms baseline-composition,baseline-toplevel` (updated in `baselines/README.md`).

### Arm R (rebuild-dedup): the win is real, and it is reuse-across-change

The gen-rebuild soundness oracle was re-asserted on the REAL corpus (nodes =
`shared` + the three hosts; edge `host → shared`; `recompute host` forces the
host's real `compositionNames`): `resultEqualsFullRebuild = true`,
`coneOnlyRecompute = true` (a poisoned recompute proves the untouched hosts are
never re-evaluated), reproduced bit-identically across two runs. A single-host
edit's cone is `[thatHost]`; the saving = Σ of the **skipped** hosts'
`baseline-composition` counters — for an edit at bitstream, **66.7% of the fleet
composition `nrFunctionCalls`** (blade + cortex skipped). The pessimal shared-node
edit recomputes the whole cone (saving 0). As §rebuild-dedup already states, this
is incremental reuse-ACROSS-CHANGE, not a single-eval speedup.

**Cross-plane note (pre-empts the obvious objection).** This 35,350,336-fcall
saving is the SEPARATE-per-host (deploy-time / cross-eval) recompute of blade +
cortex — the plane where each host is evaluated in its own process across a change.
It is the same declaration work that the Arm-C keystone (§Arm-C reconciliation pt2)
shows is nearly FREE to share WITHIN one eval (blade + cortex = 18.8M ≈ 1.066× a
single host, not the 35.35M naive sum). Different execution planes, not in tension:
Arm R saves the cross-eval recompute a change would otherwise repeat host-by-host;
Arm C's keystone measures the in-eval DECLARATION plane where native memoization
already shares it. The **third plane** is the in-eval REALIZATION plane, measured by
Task 7b (§Task 7b below): forcing both hosts' `systemd.units` from one `out` costs
**≈ 1.5× a single host** — NOT the declaration keystone's 1.066×, because host-specific
config *resolution* (unlike declaration) is not natively shared. Task 9 quotes all
three — the same class work seen from the cross-eval, in-eval-declaration, and
in-eval-realization planes. The productized mechanism that collapses the third
(realization) plane's spine — hand the class core to the merge kernel as a fixed input so each
member resolves only its delta — is `github:sini/gen-class`'s tier-2 `applyCoreFixed` (over
gen-merge's fixed-input kernel), gated in the gen hub perf-bench `classShare` workload at a ~5.8×
spine reduction (§Task 7b "Mechanism source"). This lab measures the plane; gen-class gates the
mechanism.

### Arm C (class-share): byte-SOUND, but NO composition win in this harness — reconciling the ~60% prior

Both byte gates pass (composition digest AND terminal drvPath byte-identical under
s2, all three hosts) — s2 is a correct resolution-only optimization. But the
composition-counter DELTA is **positive**: s2 costs a consistent **~+0.81M
`nrFunctionCalls` (~+4.6%) on every host** (host- and witness-invariant — the
options walk and the `cfg.config` secondary agree to within ~1000 calls). This is
s2's per-host machinery overhead (pipe.reads cone-expander + per-sid
`hostConfigFor`), NOT a win. Three reasons the ~60% Plane-2a prior does not
reproduce here — reconciled, not contradicted:

1. **Different plane.** The ~60% prior is a CROSS-HOST fleet-eval-sharing collapse
   (share class work across hosts of a class in ONE eval). `fleet-stats` evaluates
   each host in a SEPARATE process — no cross-host thunk sharing is structurally
   possible, so s2's sharing cannot manifest and only its overhead shows.

2. **The declaration layer is already shared** (keystone — reproducible). Forcing
   blade + cortex `compositionNames` from ONE shared `out` (both nixpkgs-master,
   pinned den) costs **18,836,571 `nrFunctionCalls`** — only **1.066×** a single
   host (blade `baseline-composition` = 17,673,112), NOT 2× (the naive per-host sum
   is 35,350,336 — which is exactly Arm R's separate-per-host saving in
   §rebuild-dedup: the same declaration work on the cross-eval plane, where it is
   NOT free, is what gen-rebuild avoids re-running host-by-host across a change).
   Native Nix thunk memoization already collapses the shared option-declaration tree
   in-process, so there is nothing there for s2 to dedup; its win lives one layer
   down, in config RESOLUTION. Reproduce (from the repo root):

   ```sh
   NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/keystone.json nix eval --impure --raw --expr '
   let
     nc = builtins.getFlake "github:sini/nix-config/8f84aa62168994714d5dc18459d4c5fe96650239";
     lib = nc.inputs.nixpkgs-master.lib;
     hola = import ./. { inherit lib; };
     raw = import (nc.outPath + "/flake.nix");
     out = raw.outputs (nc.inputs // {
       self = out // { outPath = nc.outPath; inherit (nc) sourceInfo; };
       nixpkgs-master = nc.inputs.nixpkgs-master // { lib = nc.inputs.nixpkgs-master.lib; };
     });
     compOf = host: hola.adapter.compositionNames out.nixosConfigurations.${host};
   in builtins.deepSeq [ (compOf "blade") (compOf "cortex") ] "two-host-forced"'
   jq -c '{nrFunctionCalls,nrPrimOpCalls,nrOpUpdateValuesCopied,nrThunks}' /tmp/keystone.json
   # {"nrFunctionCalls":18836571,"nrPrimOpCalls":5386089,"nrOpUpdateValuesCopied":5746283,"nrThunks":21676083}
   ```

   (`nrFunctionCalls`/`nrPrimOpCalls` are preamble-invariant; `nrOpUpdateValuesCopied`
   / `nrThunks` may shift ±1–2 under a different preamble — see the
   `dedup-savings.json` `pinNote`. The 1.066× ratio is unaffected.)

3. **No terminating witness reaches the resolution layer.** The only
   derivation-free witness that completes cleanly is the options walk (declaration
   layer). `cfg.config` (the resolution layer where s2 helps) does not terminate:
   its `deepSeq` hits a derivation's `outputsList` and **stack-overflows —
   uncatchable by `builtins.tryEval`** — so the secondary witness measures
   work-up-to-a-deterministic-crash (informational; delta only). A definitive
   cross-host resolution-layer witness (a derivation-pruned `cfg.config` walk
   forced across class-hosts in one eval — the fleet-eval-sharing plane) is future
   work; the current per-host harness structurally cannot capture the class-share
   win. This is exactly the under-report the §baseline-composition concern box
   predicted, taken to its conclusion.

**→ In-scope measurement (Task 7b).** The class-share win DOES exist at the
realization plane, and §Task 7b below measures it there — force a class archetype's
`systemd.units` projection once, inject its byte-identical shared core into a member
(fixed-input config-merge), pay only the member's delta, byte-gated. On the real
2-member class {blade, cortex} it is a genuine but SMALL win (~1.6% fcalls / ~0.18%
`//`-copies per added member), for a structural reason this section already implies:
the shareable projection (`systemd.units` values) is only ~2% of a member's eval, and
the dominant config-resolution spine is host-specific and unshared. The number is
pinned in `baselines/class-share-realization.json`.

## Task 7b — the shared-eval class-share arm (realization plane)

Task 7's `class-share` arm lives at the DECLARATION layer under a SEPARATE-per-host
harness, and there den@s2 is +4.6% overhead (§Arm-C). That is an airtight scope
finding, not the whole story: the class-share win is a SHARED-process,
REALIZATION-level phenomenon — the "instantiate pattern" (force a class archetype's
resolved projection once; inject it into members; pay only the per-member delta).
Prior work realized this on a SYNTHETIC 96-host class (`system.path` 4.38×,
`systemd.units` 1.89× via `extendModules`+`mkForce`, 2.48×+ via fixed-input
config-merge — `~/Documents/papers/hola-architecture/analysis/experiments/synthetic-fleet/instantiate-pattern-realization.md`).
Task 7b reproduces that measurement ON THE REAL CAMPAIGN CORPUS, byte-gated, under
campaign discipline, so the public report pins a real class-share number in its
honest scope. The number and its full framing are in
`baselines/class-share-realization.json`; this section is the protocol.

### The recon decision — Option A (the class definition)

The corpus is 3 heterogeneous REAL hosts (bitstream/unstable, blade+cortex/master),
with no synthetic class. The instantiate pattern needs an archetype shared by ≥2
members. **Decision: Option A — a 2-member ad-hoc class {blade, cortex}** (both
master channel, sharing den's module set). This is NOT a den-DECLARED class (den's
classes are nixos/home-manager/user, not host-groups); it is an ad-hoc class whose
"shared core" is the byte-identical projection intersection and whose **archetype is
one real member (blade)**. Option B (extend the corpus with a genuine near-homogeneous
class, e.g. axon k3s nodes) is heavier and only warranted if A were unsound — it is
sound (byte gate passes, §below), so A stands; Option B would likely show a larger
shared fraction and is the natural follow-up.

**"Per-added-member" at N=2** is the single marginal of adding cortex to the class
whose archetype is blade: it is ONE data point, not a slope across many members (the
synth work's slope came from M=2→48). Stated honestly with that small-N caveat, the
marginal still reads: vanilla realizes cortex's full projection; injected realizes
only cortex's delta.

### Mechanism — fixed-input config-merge (the prior work's `shareClassProjection`)

Projection = `systemd.units` (a co-produced attrset). `system.path` — the synth
work's biggest projection (4.38×) — is NOT class-invariant across these heterogeneous
reals (different `systemPackages` ⇒ different `system-path` drvPath, verified: blade
`58qq1q6…` ≠ cortex `xga0yjg3…`), so a whole-leaf `mkForce` injection of it would
FAIL the byte gate. Only the byte-identical `systemd.units` core is soundly shareable.

```nix
sharedKeys = builtins.filter (k: toJSON blade.units.${k} == toJSON cortex.units.${k})
                             (common keys);            # the byte-identical intersection (ORACLE)
core       = getAttrs sharedKeys blade.config.systemd.units;              # archetype core, forced ONCE
injected   = core // builtins.removeAttrs cortex.config.systemd.units sharedKeys;  # member = core ∪ its delta
```

`sharedKeys` is computed here by a byte-identical-intersection oracle (forcing both
hosts); a real den-hoag class boundary would supply it STRUCTURALLY, so the
measurement models the ceiling given a known boundary. **The byte gate** (the
pattern's own gate): `toJSON injected == toJSON cortex.units` — a hard fail on
mismatch. config-merge does a plain merge on RESOLVED configs (no `extendModules`
re-eval), so it reassembles a consumed projection but NEVER a per-host toplevel (the
prior work's structural limit — do not claim a toplevel win).

**Why config-merge and not `extendModules`+`mkForce` here.** The synth work's other
mechanism (`extendModules`+`mkForce`, 1.89× on units) works when members are
hostName-VARIANTS of the archetype (it re-runs `evalModules` on the archetype + a
patch, sharing the base fixpoint). On HETEROGENEOUS reals the member (cortex) is not
a variant of the archetype (blade): `blade.extendModules { … = mkForce cortex.units }`
would produce a frankenconfig (blade's everything else) whose only correct field is
the injected projection, AND it pays a full per-member `evalModules` re-run — the
memory-monstrous path the prior work flagged at scale. config-merge is the sound,
lighter, today-usable mechanism for a real heterogeneous pair; `extendModules` is
measured only in the synth prior (`priorContext`), not reproduced here.

### Commands + observed stubs (nix 2.34.7, ×2 reps, STOP-on-diff)

One documented driver — `ci/bench/class-share-realization.sh` (self-contained,
impure-local getFlake on the pinned corpus; `ulimit -s unlimited` inside). It runs
the oracle, measures three forces ×2 (deterministic-counter STOP-on-diff), asserts
the byte gate, records the `system.path` soundness check, and takes the informational
realization-plane native-share probe; it emits `facts.json` (measured verbatim) which
the `baselines/README.md` jq generator shapes into the committed baseline.

```sh
cd ~/Documents/repos/hola
bash ci/bench/class-share-realization.sh --out /tmp/csr    # ~5–6 min; green ⇒ byte gate + ×2 repro held
```

- **oracle** — archetype(blade)=257 units, member(cortex)=278, common=243,
  **byte-identical shared core = 212** (76.3% of cortex's units), `sharedKeysDigest`
  `3d8d75a5…`.
- **archetype** (blade full, 257 units): `nrFunctionCalls` 41,296,723 /
  `nrOpUpdateValuesCopied` 100,738,064; digest `f9ac1333…`.
- **reconstruct** (cortex full, 278 units — vanilla): 46,261,629 / 109,715,177;
  digest `5aefc0b2…`.
- **inject** (cortex delta, 66 units — shared core from archetype): 45,528,833 /
  109,519,756; digest `f79a7517…`.
- **byte gate**: `injected == real`, `injectedDigest == realDigest == 5aefc0b2…`
  (== the reconstruct digest), core 212 units. PASS.
- **per-added-member (cortex) saving** = reconstruct − inject: **732,796
  `nrFunctionCalls` (~1.6%)**, 195,421 `//`-copies (~0.18%), 1,065,697 thunks (~1.5%).
- **realizationPlaneNativeShare** (informational, ×1): both hosts' `systemd.units`
  from ONE `out` = 65,193,248 `nrFunctionCalls` ≈ **1.49× a single host** (25.5%
  cheaper than the separate-process sum), NOT the declaration keystone's 1.066×.

### Outcome

The class-share win is REAL and byte-identical at the realization plane, and **SMALL**:
config-merge injection of the 212-unit shared `systemd.units` core saves ~1.6% fcalls
/ ~0.18% `//`-copies per added member. It is small for a structural reason the G6
split already implied — `systemd.units` VALUE realization is only **~2% of a member's
eval**; the host-specific config-resolution SPINE (~98%) dominates and config-merge
does not share it across genuinely-distinct hosts. This is **NOT** a toplevel claim
and **NOT** 1:1 comparable to the synth 96-host 1.89×–4.38×: those measured
HOMOGENEOUS `extendModules`-variant members (config spine shared by construction) plus
`system.path`'s expensive buildEnv leaf (class-invariant there) — neither holds for a
real heterogeneous pair. What den-hoag must make shareable to reach the synth-projected
wins is precisely that config-resolution spine (inject the class core as a fixed module
input so each member resolves only its delta). Full framing + all counters:
`baselines/class-share-realization.json`; reproduction: `baselines/README.md`
§class-share-realization.

**Mechanism source — `github:sini/gen-class`.** This driver's oracle / injector / probe / gate
shapes are now productized as a standalone Class-B lib, LIFTED from here, not reinvented: the
byte-identical-intersection oracle is `mkCore`, the fixed-input config-merge injector
(`shareClassProjection` above) is `applyCoreMerge`, the class-invariance probe is `invariantUnder`,
and the byte gate is `gateCore`. The spine-SKIPPING tier-2 engine — hand the class core to the
merge kernel as a fixed input so each member resolves only its delta (the "inject the class core as
a fixed module input" this section names as den-hoag's target) — is `applyCoreFixed` over
gen-merge's fixed-input kernel; its number is gated in the gen hub perf-bench `classShare` workload:
a **~5.8× spine reduction** (fixed builds only ~0.17× the full re-merge's thunk graph), byte-identical,
permanently gated ≤ 0.30 against the A1 1.89×→2.48× spine-tax band. This lab measures the class-share
OPPORTUNITY on the real fleet; gen-class ci gates the MECHANISM on a synthetic corpus.

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

**The gate (byte).** The terminal must stay byte-identical: overriding den to s1
leaves `toplevel.drvPath` unchanged (verified below — `identical: true`). A
class-share arm that moves the drvPath is a bug, not a win.

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

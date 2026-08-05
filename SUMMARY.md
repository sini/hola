# hola — what the experiment was, what it measured, and what outlived it

This document is the self-contained record of the hola experiment. It exists because the
detail hola's own files point at no longer does: every reference to
`~/Documents/papers/hola-architecture/` — in this repo's `README.md`, in `ci/bench/MEASUREMENT.md`,
in `ci/bench/baselines/README.md`, and in the project memories — is a dangling pointer. That
directory is absent; `~/Documents/papers/` contains only `den-architecture`. Read this file as the
surviving summary, and the committed baselines under `ci/bench/baselines/` as the surviving
evidence.

Every figure below is cited to the file it was read from. Nothing is recalled or re-derived.

## 1. What hola is

**The question.** Can a pure-gen module engine host *unmodified* nixpkgs/NixOS modules — and can a
fleet of hosts share evaluation work rather than each paying full price?

Two codenames divided the space: *adios* replaces the module system; **hola keeps nixpkgs** and
replaces only the evaluator underneath it (`project_hola.md`). hola is a flake plus a module
framework hosting unmodified nixpkgs modules through the gen ecosystem and den's HOAG edge model.
Public repo: `github:sini/hola`.

**The approach — parity first, then measurement.** hola is built as an apparatus, not a product.
Its four namespaces (`README.md` §Overview) are a corpus of modules under test, an adapter that
runs a module set through both a candidate engine and the nixpkgs reference, a **parity oracle**
that compares the two, and a compose layer wiring them into runs. The rule the whole design turns
on: no counter or timing delta counts until both sides produce **byte-identical output**
(`ci/bench/MEASUREMENT.md` §2, and the A1 report §1 in
`den-architecture/specs/2026-07-05-a1-fleet-measurement-report.md`).

**Status: research lab, backgrounded.** It is a measurement lab for the gen trust push, not a
den-hoag dependency, and its findings have already been fed into the gen module system
(`project_hola.md`). Do not treat it as a live arc.

**Two arms shipped.** The *engine* arm — byte-identical `evalModules` ownership in pure Nix — and
the *perf* arm — the fleet-eval measurement campaign. Both completed; the campaign's numbers are
committed baselines with permanent regression gates (`ci/bench/fleet-gates.sh`).

> **README caveat.** `README.md` was last committed at `b1d2a28` (2026-06-23) and says hola "does
> not (yet) implement the engine" and that the engine arm is a commented placeholder. That is
> **stale**: the engine landed the next day (`beb4223` vendor body, `11a8f6d` `mkEngine`, `0033d34`
> the `engineParity` gate, `44131d1` the non-vacuity probe, all 2026-06-24) and
> `ci/tests/engine-parity.nix` gates `vanilla == engine` on six fixtures today. The README's test
> inventory ("29 tests across smoke, oracle, adapter, corpus, landmines, self-parity") likewise
> predates the `engine-parity`, `den-parity`, and `den-fleet-parity` suites now in `ci/tests/`.

## 2. What hola found

### 2.1 Owning the evaluator is nearly free — so the win is not in the engine

The engine arm's mechanism (E1, "vendor and own the seam") extends `lib` so that `final.modules`
is replaced by a vendored copy of nixpkgs' `lib/modules.nix`. Overriding `final.modules` **alone**
propagates the whole module surface, and because `final.types` is re-fixpointed it reaches the
vendored `evalModules` at the submodule base — so the vendored file-local `extendModules` owns
every recursion level including the base re-entries, ownership a naive identity-extend engine
cannot reach (`project_hola_engine.md`; the implementation is `lib/engine/default.nix`, 28 lines).

The measurement that redirected the entire program:

> **Owning `evalModules` via lib extension is ~FREE — +9 primops and +0.24% thunks one-time, with
> per-eval cost identical. Therefore the win levers are NOT in the engine itself; they are in the
> fleet axis.** (`project_hola_engine.md`)

Conditions the byte-identity claim rests on, all load-bearing (`project_hola_engine.md`): identity
is only meaningful when the vendored body, the template's nixpkgs, and the pin all agree — the two
module bodies differ by **218 lines** across versions, so pinning turns any divergence into an
unambiguous library escape rather than noise. The runner must be **channel-seeded**; a single
global engine seeded from the hola root produces an artificial foreign-lib build. The
self-reference must be a pure lazy knot; a bare `self` throws.

### 2.2 Within CppNix the evaluator levers are exhausted; only work-reduction helps

From `project_hola.md`:

- Parallel eval **does not thread** on CppNix 2.34.7 — the flag is accepted and does nothing; the
  ~3.7× is Determinate-only.
- Streaming / force-and-drop does **not** lower peak RSS: Boehm GC grows to the cumulative
  high-water mark and does not return memory to the OS.
- A larger initial heap buys ~7%.
- Eval is single-thread-bound, so **wall == work**.
- **Copies is the discriminating metric**, not function calls — the nixpkgs base is thunk-memoized
  across same-system peers, so fn-calls barely move.

### 2.3 The cost is intrinsic, not the framework

From `project_hola_perf.md`:

- **Cortex's ~36 s eval is 94% intrinsic derivation construction.** den / nix-effects / dendritic
  assembly is only ~2.8% of wall; total module machinery ~5.6%; the module check is negligible.
  About 95% of the copies are closure-forcing, not package-set construction. *An earlier
  recollection had this inverted — the framework is not the cost.*
- **Wall is single-threaded-eval bound, not GC-bound.** GC knobs cut cpuTime by 42% but wall by
  only 6%. Decomposition: ~63% serial single-threaded eval, ~30% IO, ~6% GC.
- Splicing is off for a native host (build == host), so forking nixpkgs cannot win back a cost
  that is never paid. **Forking nixpkgs construction is a dead end**; a framework reimplementation
  is a ~30% CPU / iteration / CI lever but moves copies by −0.3%, so it is not the 36 s.
- The free win is the evaluator: a parallel-eval evaluator on this exact fleet workload shape,
  verbatim nixpkgs, zero code.

### 2.4 The cross-scope sharing NO-GO — the rigorous negative

Pure-Nix cross-scope eval-result sharing, single-host and cross-host heterogeneous, is a **NO-GO**,
refuted across two adversarial workflows on four load-bearing claims (`project_hola_perf.md`).
The deliverable is the negative, and it generalizes:

1. **No sound single-host net win** — a per-element sentinel forces an invariant option N+1 times
   against vanilla's N. Nix memoizes nothing across separate module fixpoints, so the deep force
   re-pays exactly the laziness it skipped.
2. **A union sentinel is unsound** — throwing the union of element paths over-throws and flips
   `tryEval` branches, i.e. it over-*admits* unsafe cases. The sound universal form needs one
   sentinel per element, so there is no amortization.
3. **Presence and structure queries are unsound even per-element** — a value-throw sentinel never
   perturbs key *presence*. (`or` is safe, because it forces the value.)
4. **Memoizing by syntactic path-set is unsound** — the key is value-derived.

Soundness is intrinsic **only for the throws-observed subclass**; the boundary is non-forcing
channels. And the honest ceiling on the whole apparatus: **drvPath-equality proves output
shareability, not that eval work was shared**, so a parity gate is a mandatory backstop
(`project_hola.md`).

**Scope correction (owner, recorded in `project_hola_perf.md`) — do not cite the NO-GO as a blanket
ceiling.** It applies to hola *as architected*: per-element sentinel **discovery**. The lever is
**declaring** the host-class boundary, not discovering it, and at fleet scale the sign flips
positive. This is hola's stable thesis: *declare the host-invariant boundary, do not discover it* —
per-element discovery is O(N) and net-negative, while declaring a host **class** (key = the sorted
aspect-include set, **not** the hostname) and validating O(K) per class is N-independent
(`project_hola.md`).

### 2.5 The fleet campaign — the dedup opportunity is plane-shaped

The campaign forced the real den fleet pinned by `github:sini/nix-config` @ `8f84aa6` — three
heterogeneous hosts (bitstream on unstable, blade and cortex on master) — under deterministic
evaluator counters, byte-gated first. Protocol: `ci/bench/MEASUREMENT.md`. Numbers:
`ci/bench/baselines/{g6-split,dedup-savings,class-share-realization}.json`, summarized in
`ci/bench/baselines/README.md`.

**The G6 split — composition is a minority of the terminal** (nix 2.34.7,
`baselines/README.md` §The split, from `g6-split.json`):

| host | nrFunctionCalls | //-copies (merge storm) |
|---|---:|---:|
| bitstream | 55.2% | 13.7% |
| blade | 40.3% | 4.1% |
| cortex | 36.1% | 3.9% |
| **fleet (Σ/Σ)** | **42.5%** | **5.2%** |

Fleet-wide, composition is only **5.2%** of the terminal's `//`-merge storm — ~95% of merge cost
lives in value/derivation realization, not declaration composition. Read these as a comparison of
**two non-nested projections of the same eval**, never as a part/whole share: the composition
witness walks *every* declared option while the terminal force reaches only the `build.toplevel`
cone (`baselines/README.md` §What the split compares). It corroborates the §2.3 time profile
directionally — cortex composition at 3.9% of the terminal storm is an *upper* bound, so the ~96%
realization residual is a conservative lower bound (`baselines/README.md` §Prior reconciliation).

**Three planes, all byte-gated** (`MEASUREMENT.md` §Task 7 amendments, §Task 7b;
`baselines/README.md` §Dedup savings, §class-share-realization):

- **Deploy-time / cross-eval (Arm R, gen-rebuild).** A localized single-host edit recomputes only
  that host's cone and reuses the rest byte-for-byte — `resultEqualsFullRebuild = true`,
  `coneOnlyRecompute = true`, reproduced bit-identically across two runs. An edit at bitstream
  skips blade + cortex: **66.7% of fleet composition `nrFunctionCalls` (35,350,336)**. This is
  incremental reuse **across a change**, not a single-eval speedup — gen-rebuild does not beat
  `O(|cone|)` in one pure eval. The pessimal shared-node edit saves **0**, recorded honestly.
- **In-eval declaration (Arm C keystone).** Already free. Forcing blade + cortex composition from
  one shared `out` costs **18,836,571 fcalls ≈ 1.066×** a single host (blade alone = 17,673,112),
  not the 35,350,336 naive sum — native thunk memoization already collapses the shared declaration
  tree in-process. den@s2's class-share optimization is **byte-sound but +4.6% overhead** here, on
  every host: the ~60% Plane-2a prior is a cross-host sharing collapse a separate-per-host harness
  structurally cannot capture. Reconciled, not refuted. At the terminal plane s2 costs a further
  **+1.3–2.4% fcalls** (bitstream 2.37% / blade 1.49% / cortex 1.33%, fleet +1.65%) on a
  byte-identical drvPath — an overhead record, explicitly **not** a win, so it carries no floor.
- **In-eval realization (Task 7b).** Real, byte-identical, and **small**. On the ad-hoc 2-member
  class {blade, cortex} with blade as archetype and `systemd.units` as the projection: the
  **212-unit byte-identical shared core** (76.3% of cortex's 278 units) injects byte-identically
  and saves **732,796 fcalls (~1.6%)** and **195,421 `//`-copies (~0.18%)** per added member. Small
  for a structural reason: `systemd.units` value realization is only **~2% of a member's eval**;
  the host-specific config-resolution **spine (~98%)** dominates and config-merge cannot share it
  across genuinely distinct hosts. Natively, both members' units from one `out` cost **≈1.49×** a
  single host — not the declaration layer's 1.066×.

**That spine is the concrete target.** hola's own conclusion: what den-hoag must make shareable to
reach the synthetic-fleet projections is precisely the config-resolution spine — inject the class
core as a *fixed module input* so each member resolves only its delta (`MEASUREMENT.md` §Task 7b
Outcome).

### 2.6 Durable protocol findings

These generalize past hola and are the reason its measurement discipline was worth keeping:

- **A version string does not identify an evaluator build.** CI's Determinate Nix and the
  baselines' CppNix both print `nix (Nix) 2.34.7`, yet Determinate measured **`nrPrimOpCalls` −8**
  on the deep evals (~4e-7 relative) with every other counter and digest identical. So an exact
  counter gate is same-build-only; cross-build regression detection needs a **±0.1% relative band**
  (`MEASUREMENT.md` §"Same version number ≠ same evaluator build"; `project_hola.md` records the
  same finding as "two builds differed by 8 primops").
- **`gc.totalBytes` is never a gate** — a Boehm total-allocation number that drifts ~1e-6..1e-5
  run-to-run; informational only. `cpuTime` likewise (machine-dependent)
  (`MEASUREMENT.md` §Counter determinism).
- **Digests are the cross-evaluator spine** — drvPaths and structural sha256s are determined by the
  pinned inputs, not the Nix build, so they gate exactly everywhere (`baselines/README.md`
  §Digests everywhere).
- **A gate that prints only FAIL is not an instrument** — both counter tiers print a per-counter
  expected/actual/delta table on violation, and `fleet-gates.sh --selftest` proves the teeth by
  corrupting a baseline copy and asserting the sweep fails (`baselines/README.md` §Teeth).
- Full-fleet `deepSeq` is memory-monstrous and will OOM the machine; scaled evals need
  `ulimit -s unlimited` and `--option max-call-depth 1000000`; a universal deep-force trips
  removed-option stubs and readFile assets, so force assertion **predicates**, not whole subtrees
  (`project_hola.md`).
- The authoritative gate is `cd ci && nix flake check`, proven non-vacuous by a break-test; the
  `nix-unit --flake` CLI **under-reports** here and must not be used as the gate
  (`project_hola_engine.md`).
- Same-priority, same-order list definitions merge in **reverse declaration order** — non-obvious,
  and it bites parity work (`project_hola_engine.md`; pinned by the `valueMeta` fixture,
  `README.md` §corpus).

## 3. What outlived hola

- **`github:sini/gen-class`** — the productization of the Task-7b realization arm. Its oracle,
  injector, invariance probe, and byte gate are *lifted* from `ci/bench/class-share-realization.sh`,
  not reinvented: `mkCore`, `applyCoreMerge`, `invariantUnder`, `gateCore`
  (`MEASUREMENT.md` §Task 7b "Mechanism source"; corroborated in `gen-class/README.md:12,258-260`,
  `gen-class/AGENTS.md:124`, `gen-class/lib/apply.nix:2`, `gen-class/lib/gate.nix:14`,
  `gen-class/ci/tests/apply.nix:2`).
- **The spine-skipping mechanism itself** — gen-class's tier-2 `applyCoreFixed` over gen-merge's
  fixed-input kernel, gated in the gen hub's perf-bench `classShare` workload at **~0.17× the full
  re-merge's thunk graph (a ~5.8× spine reduction), byte-identical, permanently gated ≤ 0.30
  against the A1 1.89×→2.48× spine-tax band** (`gen/BENCHMARKS.md:31`). The threshold band is
  hola-derived.
- **The fleet numbers as gen's public trust evidence.** The audit path is **gen → hola →
  nix-config** (`gen/VALIDATION.md:401-403`, `gen/BENCHMARKS.md:123-134`). The three baseline JSONs
  are committed verbatim into the gen hub, where `nix run ./ci#fleet-consistency` re-asserts their
  arithmetic without a fleet eval; **hola remains the only re-measurement home**
  (`ci/bench/baselines/README.md` §Consistency-pin home — the note added by this repo's HEAD commit,
  `3e449ac`).
- **The measurement discipline** — byte-gate-first, two-tier counters, never-gate-`gc.totalBytes`,
  floors that update in-PR and are never deleted — restated as the gen hub's own gate policy
  (`gen/BENCHMARKS.md` §Gate policy).
- **The stack-raising nix-unit hook.** hola's local `ci/precommit.nix` override migrated to its
  durable home in gen's `mkCi`; hola's `ci/flake.nix` now records that the wrapper "comes from gen's
  mkCi itself (flakeModule.nix, since gen@6d259ef)" and the local override is deleted.
- **den-side branches** `feat/s1-per-sid-hostconfig` and `feat/s2-pipe-reads`, published on
  sini/den; whether to fold them into den-hoag rather than ship to denful/den was left open
  (`project_hola.md`). Note `MEASUREMENT.md` §class-share records them as **local-only worktree
  branches** at campaign time, which is why Arm C is impure-local by design.

---

# Addendum — how hola shaped gen's custom module system

## A. The ruling, and what corroborates it

The owner ruling of 2026-08-05 is recorded as
`den-architecture/specs/adr/0005-gen-rebuild-hola-findings.md` (status **CONDITIONAL**):

> gen-rebuild is from the hola experiment, and hola's findings should have informed the
> implementation details of the gen module system (gen-merge, gen-flake, gen-types, and the
> module-system audit generally).

**The gen-rebuild lineage is documented — in den-architecture, not in gen-rebuild.** The design
spec `den-architecture/gen-specs/gen-rebuild/2026-06-23-gen-rebuild-design.md` opens by naming its
input: the operation surface and theory grounding are "see `hola-architecture/analysis/gen-rebuild-surface.md`
(the **Phase-1 output this spec builds on**)" (`:5`). The same spec threads hola through its design
decisions — hola's lazy selection supplies the per-host key for cross-eval result reuse (`:39`,
`:124`), the HOAG graph supplies dependency edges at "hola Phase 4" (`:65`), and the synthetic den
cross-host example "becomes the hola Phase-5 seed" (`:140`). That is direct documentary lineage.
Note that the cited Phase-1 file is itself now unreachable (§0 above).

**A nuance, not a refutation.** Repo creation order runs the other way: gen-rebuild's scaffold
commit `6e8d574` is 2026-06-23T18:40:35-07:00 and hola's `1df93ee` is 2026-06-23T21:45:39-07:00 —
gen-rebuild's repo is ~3 hours older. The ruling is about the *experiment* (the papers-level hola
architecture work that produced the Phase-1 surface analysis), which preceded both repositories, not
about which git repo was initialized first.

## B. Where hola's findings did land

| Landing | Evidence |
|---|---|
| **gen-class, wholesale** — the realization-plane mechanism, four named functions lifted from hola's Task-7b driver | `gen-class/README.md:12,258-260`; `gen-class/lib/apply.nix:2`; `gen-class/ci/tests/apply.nix:2` |
| **gen-class's counter policy** — the two-tier exact/relative gate, documented by reference to hola | `gen-class/lib/gate.nix:14-22` cites `hola ci/bench/MEASUREMENT.md` §"Counter determinism" |
| **The gen hub's spine gate threshold** — `classShare` gated ≤ 0.30 "against the A1 1.89×→2.48× spine-tax band" | `gen/BENCHMARKS.md:31` |
| **The gen hub's fleet section** — the G6 split, all three planes, the gate policy, reproduced with hola cited as the lab | `gen/BENCHMARKS.md:123-200`; `gen/VALIDATION.md:62,401-403,411-489` |
| **The `ulimit`/stack-raising CI hook** — migrated from hola-local to gen's `mkCi` | hola `ci/flake.nix` comment; `ci/bench/baselines/README.md` §The `ulimit` fix |

The pattern: hola's findings landed **at the hub level and in gen-class**, both of which cite hola
by name and by rev.

## C. Lineage claims that could NOT be corroborated — UNVERIFIED

- **UNVERIFIED: that hola informed gen-rebuild's *library* documentation or implementation.** The
  string `hola` does not occur anywhere in the gen-rebuild repository — `grep -rl "hola"
  gen-rebuild/` returns nothing, while the same instrument in the same run returns hits in
  `gen-class/` and `gen/`. gen-rebuild's `AGENTS.md` §Theory credits Mokhov 2018, Reps–Teitelbaum–Demers
  1983, Acar 2002, Forgy 1982, Adapton, Radul–Sussman, Datafun, Sloane, and Tarjan — hola appears in
  none of them. The lineage is real (§A) but lives entirely outside the library that carries it.
- **UNVERIFIED: that hola informed gen-merge's warm path.** `grep -rl "hola" gen-merge/` returns
  nothing. gen-merge attributes the warm path to a *different* ancestor, twice: "Warm is the
  reverse-cone reuse of **adios**'s `mkOverride`, but sound under gen-merge's config *fixpoint*
  (adios has none)" and "This is **adios**'s 'what was reused vs re-evaluated,' delivered as data"
  (`gen-merge/README.md` §Warm re-eval; restated in `gen-merge/AGENTS.md` §Theory).
- **UNVERIFIED: that hola informed gen-flake's compose/observability or its cold-parity oracle.**
  `grep -rl "hola" gen-flake/` returns nothing. gen-flake's invariant "warm is an optimization,
  never a semantics change," standing behind `test-cold-parity-force` and
  `test-chain-warm-equals-manual` (`gen-flake/AGENTS.md` §Theory), is *structurally* the same
  discipline as hola's `vanilla`-vs-`engine` byte gate — a candidate fast path held to
  byte-identity with the reference. Whether that is influence or convergence cannot be established
  from either repo; gen-flake's Theory section states plainly that no academic result is claimed and
  cites no lab.
- **UNVERIFIED: the ">70% memory reduction" figure.** `project_hola_perf.md` records the owner
  correction that the gen module system overcame the NO-GO "via fixed-input class-core injection
  plus warm-override memoization, reaching >70% memory reduction with re-compute avoidance as a key
  win." Searching `gen/`, `gen-merge/`, `gen-class/`, `gen-flake/`, and `hola/` for `70%` returns
  exactly one hit, an unrelated code-share bar in `hola/ci/bench/baselines/README.md:642`; the
  positive control (`66.7`) hits four times across `gen/` and `hola/` in the same run. The two named
  *mechanisms* are verifiably present — gen-merge's `coreShortCircuit`/`mkCoreValue` fixed-input
  kernel and its `warmFrom`/`editedModules` warm path, gated in the gen hub as `classShare` (~0.17×
  thunks) and `overrideWarm` (~0.17× thunks and allocation, ~5.9× reuse) at `gen/BENCHMARKS.md:31,33`.
  The **memory** figure is not among them; the hub's gates are thunk-graph and allocation ratios.

## D. Gaps — hola findings that measurably did not land

Stated as facts, with the instrument that establishes each absence.

1. **The NO-GO's four unsoundness results are recorded nowhere in the module system's own docs.**
   The union-sentinel over-admission, the presence/structure-query unsoundness, and the
   syntactic-path-set unsoundness (§2.4) are constraints on any future sharing mechanism. They
   appear in `project_hola_perf.md` and (formerly) the papers archive. `grep -rl "hola"` over
   gen-merge, gen-flake, and gen-rebuild returns nothing, so no library that could re-derive a
   sharing shortcut carries the record of why the obvious ones are unsound. gen-class encodes the
   *positive* replacement — a declared boundary whose gate, not its key, is authority
   (`gen-class/README.md:68-70`) — but not the negative that motivates it.

2. **The "owning `evalModules` is ~free" verdict does not frame gen-merge.** hola measured engine
   ownership at +9 primops / +0.24% thunks one-time and concluded the win levers are not in the
   engine (§2.1). gen-merge is a from-scratch pure-Nix `evalModules` reimplementation. Its docs
   carry no reference to that measurement. This is not a contradiction — gen-merge's stated purpose
   is nixpkgs-lib-freedom and a swappable merge kernel, not evaluator speed — but the measurement
   that would set expectations for it is absent from the library.

3. **The Arm-R gate migration named in hola's own lifecycle plan has not happened.**
   `ci/bench/baselines/README.md` §Lifecycle states that the durable regression home for the
   incremental-rebuild mechanism "migrates to gen-rebuild's own CI when roadmap-A3 productizes it,"
   after which hola's Arm-R gate becomes a cross-reference. gen-rebuild's `ci/tests/` contains 18
   suites, none fleet-related; `grep -rn "fleet\|A3" gen-rebuild/ci/` returns nothing. The Arm-R
   floor (`>= 0.60`, measured 0.667) still lives only in `hola/ci/bench/fleet-gates.sh`.

4. **The two-tier counter policy is a hub-and-gen-class asset, not a per-library one.** It landed in
   `gen-class/lib/gate.nix` and the gen hub's gate policy (§B), but gen-merge and gen-flake carry no
   counter gates at all — their CI is `nix flake check ./ci` (both `AGENTS.md` §Checks). A
   performance regression in the merge engine or the composition boundary would not be caught by the
   discipline hola established, only by the hub's aggregate perf-bench.

5. **hola's parity apparatus was not reused for the pure engine.** hola's harness holds a candidate
   evaluator to nixpkgs byte-identically over a corpus (`compose.selfParity`, `compose.engineParity`,
   plus the fleet drvPath gate on three real hosts). gen-merge — the actual pure engine — validates
   against nixpkgs through its own `ci/` oracle suite instead; `grep -rl "hola" gen-merge/` returns
   nothing, and hola's corpus/adapter/parity namespaces have no consumer outside hola. The
   apparatus built to hold a pure engine accountable is not the one holding the pure engine
   accountable.

## E. The one-line disposition question this record feeds

ADR-0005's consequence clause: gen-rebuild's disposition — fold into the module system's design, or
remain a substrate lib — is settled in the gen premise document with this lineage in evidence. What
this record contributes: the lineage is documentary and real (§A), gen-rebuild's measured fleet win
is on a **different execution plane** from the module system's warm/fixed-input wins (§2.5 — Arm R
is cross-eval reuse across a change; `classShare`/`overrideWarm` are in-eval), and gen-rebuild today
is off-roster with `gen-resolve` its sole consumer (`gen-rebuild/AGENTS.md` §Scope).

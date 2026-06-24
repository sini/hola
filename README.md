# hola — parity harness for a pure-gen module engine

[![CI](https://github.com/sini/hola/actions/workflows/ci.yml/badge.svg)](https://github.com/sini/hola/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/sini)

hola is a **parity harness**: it dual-runs nixpkgs' `lib.evalModules` against a
future pure-gen module engine over the *same* unmodified nixpkgs modules, and
asserts the two agree. The engine is meant to host unmodified nixpkgs modules
faster, so the only thing that matters is that it is **observably identical** to
the reference — hola is the apparatus that proves it.

## Table of Contents

- [Overview](#overview)
- [Terminology](#terminology)
- [Gen Ecosystem](#gen-ecosystem)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Testing](#testing)
- [Theoretical Foundations](#theoretical-foundations)
- [License](#license)

## Overview

hola does not (yet) implement the engine. It stands up the **harness** that will
hold the engine accountable to the reference:

```
corpus    (the modules under test)   unmodified nixpkgs modules + fixtures
   │
adapter   (the engine boundary)      runs a module set through engine + reference
   │
parity    (the oracle)               compares the two results, reports divergence
   │
compose   (the wiring)               binds corpus + adapter + parity into runs
```

It is a leaf gen library: `{ lib }`-only, depending on nothing but `nixpkgs.lib`.
All four namespaces (`parity`, `adapter`, `corpus`, `compose`) are implemented;
the harness self-validates today (`vanilla` vs `identity`) and the engine arm
slots into `adapter.engines.engine` when it lands. See [Testing](#testing).

## Terminology

| Term | Definition |
| ------- | ----------------------------------------------------------------- |
| Corpus | the set of unmodified nixpkgs modules (and fixtures) under test |
| Adapter | the boundary that runs a module set through both engine + reference |
| Reference | nixpkgs `lib.evalModules` — the ground truth |
| Engine | the future pure-gen module evaluator hola holds to parity |
| Parity | the oracle that compares two evaluation results for divergence |
| Run | a single corpus entry put through adapter + parity |

## Gen Ecosystem

| Library | Role |
|---------|------|
| [gen-algebra](https://github.com/sini/gen-algebra) | Pure primitives (search, record, identity) |
| [gen-schema](https://github.com/sini/gen-schema) | Typed registries (kinds, instances, collections, refs) |
| [gen-aspects](https://github.com/sini/gen-aspects) | Aspect types (traits, classification, dispatch) |
| [gen-graph](https://github.com/sini/gen-graph) | Graph queries (combinators, traversals, fixpoint) |
| [gen-scope](https://github.com/sini/gen-scope) | Scope graphs (construction, evaluation, resolution) |
| [gen-select](https://github.com/sini/gen-select) | Selector algebra (pattern matching over graph positions) |
| [gen-bind](https://github.com/sini/gen-bind) | Module binding (inject args into NixOS modules) |
| [gen-derive](https://github.com/sini/gen-derive) | Rule dispatch (stratified phases, fixpoint, conflict resolution) |
| [gen-vars](https://github.com/sini/gen-vars) | Variable generation (scope-driven, multi-target) |
| [gen-rebuild](https://github.com/sini/gen-rebuild) | Incremental rebuilder (dirty-bit, dependent-cone reuse) |
| [hola](https://github.com/sini/hola) | Parity harness (dual-run engine vs reference `evalModules`) |

## Quick Start

### As a flake input

```nix
{
  inputs.hola.url = "github:sini/hola";
  outputs =
    { hola, ... }:
    let
      h = hola.lib;
    in
    {
      # use h.parity, h.adapter, h.corpus, …
    };
}
```

### Without flakes

```nix
let
  lib = (import <nixpkgs> { }).lib;
  hola = import ./path/to/hola { inherit lib; };
in
hola.parity # … etc
```

## API Reference

`import ./. { inherit lib; }` (or `hola.lib` via the flake) yields four namespaces:
`parity`, `adapter`, `compose`, `corpus`.

### `hola.parity` — the oracle

| Function | Signature | Purpose |
| --- | --- | --- |
| `force` | `a -> a` | `deepSeq x x` — fully force a value (used to surface lazy throws). |
| `diff` | `{ a, b } -> { identical; divergences }` | Structurally compare two forced values; `divergences` is a list of `{ path; aValue; bValue }`. A throw on either arm is a divergence (value `"<<throw>>"`); an absent key is `"__absent"`. |
| `diffAt` | `path -> a -> b -> [ divergence ]` | The recursive worker behind `diff`; returns the divergence list rooted at `path` (lists compare length-then-elementwise). |
| `locate` | `{ a, b } -> divergence \| null` | First divergence from `diff` (its `head`), or `null` when identical — the "where do they differ" probe. |
| `drvPathGate` | `{ a, b } -> { identical; aDrv; bDrv }` | Host-tier gate: compares `config.system.build.toplevel.drvPath` of two eval results as strings (`"<<throw>>"` on failure). |
| `expectThrow` | `projection -> bool` | True iff forcing the already-picked `projection` throws — the `gate = "throws"` oracle. |
| `withOptionShape` | `{ basePick? , options? , subOptionPaths? } -> result -> attrs` | Pick-builder: augments `basePick result` with `__optionNames` (real option names, `_module` filtered) and `__subOptions` (per-path `getSubOptions` names). |

### `hola.adapter` — the engine boundary

| Member | Shape | Purpose |
| --- | --- | --- |
| `engines.vanilla` | `{ lib; evalModules }` | The reference: raw `nixpkgs.lib` + `lib.evalModules`. |
| `engines.identity` | `{ lib; evalModules }` | `lib.extend` passthrough that routes through the same `submodule extendModules` override seam the engine arm will replace (§4 HC5) — byte-identical output today. |
| `run` | `engine -> fx -> result` | Value/synthetic/landmine tier: calls `engine.evalModules { modules; specialArgs; class? }`. |
| `runHost` | `engine -> fx -> result` | Host tier (`gate = "drvPath"`): imports `fx.evalConfig` (eval-config), threading `engine.lib` so the override reaches the host evaluator. |

Each engine record carries **both** its `lib` and its `evalModules` so `runHost` can thread a possibly-extended `lib` into eval-config. The `engine` arm is a commented placeholder (see [Testing](#testing)).

### `hola.compose` — the wiring

| Function | Signature | Purpose |
| --- | --- | --- |
| `valueEq` | `e1 -> e2 -> fx -> bool` | `(parity.diff)` over `fx.pick` of `run e1 fx` vs `run e2 fx`; picks receive the **full eval result** (default pick `r: r.config`). |
| `drvEq` | `e1 -> e2 -> fx -> bool` | `(parity.drvPathGate)` over `runHost e1 fx` vs `runHost e2 fx`. |
| `expectThrowFx` | `engine -> fx -> bool` | `parity.expectThrow` of `fx.pick (run engine fx)` — the engine:fx wrapper around the throws oracle. |
| `selfParity` | `fx -> bool` | Dispatches on `fx.gate` (`value`/`drvPath`/`throws`) and asserts `vanilla` vs `identity` agree — the contract each fixture is held to. |

### `hola.corpus` — the modules under test

Each non-floor entry is `{ mk; defaultParams; gate; tier }`; `mk params` builds a fixture.

| Entry | Tier | Gate | What it exercises |
| --- | --- | --- | --- |
| `synthetic` | `both` | `value` | Parametric `attrsOf submodule` (`n` elems, `ndecls` opts, `layers` priority contributions on `o1`) — drives `filterOverrides` / the merge fold. |
| `priorityFold` | `parity` | `value` | Priority lattice: `mkForce` (prio 50) wins over normal/`mkDefault`, `mkIf false` drops. |
| `order` | `parity` | `value` | `mkBefore < normal < mkAfter` list ordering (D6). |
| `valueMeta` | `parity` | `value` | Same-priority same-order `listOf` defs merge in **reverse** declaration order (`[1] [2] -> [2 1]`) — the non-obvious behaviour the contract pins. |
| `latticeThrows` | `parity` | `throws` | Two same-priority `mkForce` on an `int` → merge-conflict throw. |
| `realHost` | `both` | `drvPath` | Full NixOS host via eval-config (`mk { nixpkgs, n }`), `n` systemd services — gate is the toplevel `drvPath`. |
| `floor.justImport` | `perf` | — | `{ nixpkgs }` → attrNames count of the full package set (the H1 //-storm floor). |
| `floor.libOnly` | `perf` | — | `{ nixpkgs }` → `lib` version alone, no package set. |
| `floor.modScale` | `perf` | — | 200-module package-free `evalModules`. |

**Fixture contract.** A fixture (the output of `mk`) is:

```nix
{
  modules;             # the module list under test
  specialArgs ? { };   # threaded into evalModules
  class ? null;        # evalModules class, e.g. "nixos"
  pick;                # result -> projection (receives the full eval result)
  gate;                # "value" | "drvPath" | "throws"
  expected ? …;        # value-tier expected projection (landmine fixtures)
  evalConfig ? …;      # drvPath tier: path to eval-config.nix
}
```

`floor.*` entries are the exception: they are `{ tier = "perf"; expr = params -> value }` baselines, consumed by the perf apps rather than the parity oracle.

### Tier-2 evidence apps

Run from the `ci` flake (`nix run ./ci#<app>`). These are **evidence tooling — they never gate CI**; they measure the vanilla baseline only (no engine arm exists yet).

| App | Purpose |
| --- | --- |
| `nix run ./ci#stat-capture -- <fixture>` | Eval a value-tier fixture (`synthetic`/`priorityFold`/`order`/`valueMeta`) under `NIX_SHOW_STATS`, emit one-line JSON (function calls, thunks, `//`-copies, primops, GC bytes, cpu time). |
| `nix run ./ci#scaling-curve -- [fixture] [n…]` | Sweep `n` for `synthetic`, print `n / primops / ratio` (≈2 linear, ≈4 quadratic; default sweep `64 128 256 512`). |
| `nix run ./ci#floor-decomp` | Eval the three floor baselines (`justImport`/`libOnly`/`modScale`), print `component / nrFunctionCalls / nrOpUpdateValuesCopied` (the `//`-storm signature). |
| `nix run ./ci#parity-report` | Run the authoritative gate (`nix flake check` in `ci`) and emit a markdown PASS/FAIL report with the nix + nixpkgs rev and the vanilla-baseline caveat. |

## Testing

```sh
cd ci && nix flake check
```

Uses `gen.lib.mkCi` (nix-unit), with tests as
`flake.tests.<suite>.<test> = { expr; expected; }`. The suite is **29 tests
green** across `smoke`, `oracle`, `adapter`, `corpus`, `landmines`, and
`self-parity`.

**The parity contract self-validates today.** Each `self-parity` fixture asserts
that `engines.vanilla` and `engines.identity` agree under `compose.selfParity`
(value diff, drvPath-string identity, or expected-throw, per `fx.gate`). Because
`identity` routes through the same `submodule extendModules` override seam the
real engine will replace, a green suite proves the harness machinery itself is
parity-preserving before any engine exists.

**The engine arm is a seam.** When the pure-gen engine lands (next increment,
after gen-rebuild v2) it slots in as `adapter.engines.engine = { lib = holaLib; evalModules = holaLib.evalModules; }` — the commented placeholder in
`lib/adapter.nix`. Every `vanilla`-vs-`identity` assertion then gains a
`vanilla`-vs-`engine` twin with zero changes to `parity`, `compose`, or the
corpus.

> Use `nix flake check` (run from `ci`), **not** `nix-unit --flake .#tests`: the
> latter under-reports this suite. `nix flake check` is the authoritative gate.

## Theoretical Foundations

| Grounding | Relationship | Where it shows up |
|-----------|--------------|-------------------|
| Pierce (2002) "Types and Programming Languages" — observational / contextual equivalence | Informed by | The **parity contract**: two evaluators are equal iff no context (corpus fixture) distinguishes their results. `compose.selfParity` is exactly this judgement. |
| Tiered observation oracle | Implements | `hola.parity` splits the observable into a **config projection-value diff** (`diff`/`diffAt`, structural over forced values) and a **drvPath string-identity** gate (`drvPathGate`) for the host tier — value equality where values are cheap, derivation identity where they are not. |
| Order-sensitive merge (nixpkgs module system, D6) | Pinned by | The `order`/`priorityFold`/`valueMeta` landmines encode `mkBefore < normal < mkAfter` and the reverse-declaration-order same-priority list merge — the merge semantics any engine must reproduce byte-for-byte. |
| HC5 — `submodule` / `extendModules` override seam | Targeted by | `engines.identity` routes through a `lib.extend` override of `modules.evalModules`, the same seam the engine arm replaces; it is the single point where a substitute evaluator attaches. |

The nixpkgs **module system** itself (`lib/modules.nix`: `mergeDefinitions`,
`filterOverrides`, priority/order folding) is the reference semantics the whole
harness exists to pin.

**nixpkgs rev pin.** §4 of the design refers to specific `lib/modules.nix`
counters and line numbers, which are rev-sensitive; the spec pins those
references to nixpkgs `2f4f625e`. The live harness, by contrast, evaluates
against its **own flake-pinned nixpkgs** (`ci/flake.lock`), so the assertions
track whatever rev the lock resolves — the `2f4f625e` pin is for reading §4's
line citations, not for running the gate.

Full design + milestones: `~/Documents/papers/hola-architecture/`.

## License

MIT

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
The lib stubs (`parity`, `adapter`, `corpus`, `compose`) are filled in by later
tasks; this skeleton stands up the repo and the gen CI convention.

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

_TBD — filled in Task 9._

## Testing

```sh
cd ci && nix flake check
```

Uses `gen.lib.mkCi` (nix-unit), with tests as
`flake.tests.<suite>.<test> = { expr; expected; }`.

## Theoretical Foundations

| Paper | Relationship | Used for |
|-------|-------------|----------|
| Pierce (2002) "Types and Programming Languages" | Informed by | Observational equivalence — parity is contextual equivalence of two evaluators over the same module corpus |

Full design + milestones: `den-architecture/` / `hola-architecture/`.

## License

MIT

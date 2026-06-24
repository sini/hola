# Vendored nixpkgs `lib/modules.nix`

`modules.nix` here is a **byte-for-byte copy** of nixpkgs `lib/modules.nix`, vendored so the hola
engine can BE `lib.modules.evalModules` at every recursion level (E1 spec §3 / HC5). Unmodified at
E1; later increments (E3) edit it under the parity gate.

- **Source:** nixpkgs `nixos-unstable`, rev `567a49d1913ce81ac6e9582e3553dd90a955875f`
  (the harness's `nixpkgs` input — flake.lock node `nixpkgs_7`).
- **License:** MIT — see `COPYING` (Copyright (c) 2003-2026 Eelco Dolstra and the Nixpkgs/NixOS contributors).
- **K9 migration rule:** bumping the harness's nixpkgs input requires **re-vendoring** this file
  from the new rev and re-running `cd ci && nix flake check`. `nix run ./ci#vendor-check` reports
  drift against the current input.

`modules.broken.nix` is a **test fixture only** (added in a later task) — never imported by the real engine.

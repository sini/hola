# Pre-commit hook fix (Task 8): the gen `mkCi` flakeModule wires a `ci` pre-commit hook that runs
# `nix-unit --flake ./ci#tests`. hola's suite includes `den-fleet-parity`, a DEEP fleet eval that
# overflows the default 8 MB stack (the same reason fleet-stats / class-share-realization / fleet-gates
# all `ulimit -s unlimited` before their evals — MEASUREMENT.md). Two Task-7/7b implementers hit this:
# committing a `.nix` change triggers the hook, which then stack-overflows.
#
# The pre-commit framework execs `entry` directly (shlex split, NO shell), so a raised ulimit cannot be
# injected inline — it needs a wrapper binary. This module overrides the hook entry with a wrapper that
# raises the stack then execs the SAME nix-unit invocation. Scoped to hola (this repo's push); the
# durable home for this fix is gen's ci/flakeModule.nix (every gen lib's nix-unit hook would benefit),
# tracked with the same lifecycle note as the gates in ci/bench/baselines/README.md §Task 8.
{
  inputs,
  genInputs,
  lib,
  ...
}:
let
  # Same input-resolution as gen's mkCi: prefer the consumer's input, fall back to gen's.
  resolve = name: if inputs ? ${name} then inputs.${name} else genInputs.${name};
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      nixUnit = (resolve "nix-unit").packages.${system}.default;
      ciWrapper = pkgs.writeShellApplication {
        name = "hola-ci-nix-unit";
        runtimeInputs = [ nixUnit ];
        text = ''
          # The fleet eval (den-fleet-parity) is deep; the default stack overflows.
          ulimit -s unlimited 2>/dev/null || true
          exec nix-unit --flake ./ci#tests "$@"
        '';
      };
    in
    {
      pre-commit.settings.hooks.ci.entry = lib.mkForce "${ciWrapper}/bin/hola-ci-nix-unit";
    };
}

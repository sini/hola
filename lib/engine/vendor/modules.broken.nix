# TEST FIXTURE ONLY — proves the parity gate is non-vacuous (E1 spec §6).
# A correct engine reproduces the same-priority listOf reverse-order quirk ([1],[2] -> [2 1]);
# this wrapper deliberately re-reverses `config.thing`, so engineParity over `valueMeta` flips false.
# Never imported by the real engine (lib/engine/default.nix uses ./modules.nix).
{ lib }:
let
  real = import ./modules.nix { inherit lib; };
in
real
// {
  evalModules =
    args:
    let
      r = real.evalModules args;
    in
    r
    // {
      config = r.config // {
        thing = lib.reverseList (r.config.thing or [ ]);
      };
    };
}

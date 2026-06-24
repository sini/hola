{ lib }:
let
  synthetic = import ./synthetic.nix { inherit lib; };
  landmines = import ./landmines.nix { inherit lib; };
in
{
  synthetic = {
    inherit (synthetic) mk;
    defaultParams = {
      n = 50;
      ndecls = 20;
      layers = 2;
    };
    gate = "value";
    tier = "both";
  };
}
// lib.mapAttrs (_: lm: {
  inherit (lm) mk;
  defaultParams = { };
  gate = (lm.mk { }).gate;
  tier = "parity";
}) landmines

{ lib }:
let
  synthetic = import ./synthetic.nix { inherit lib; };
  landmines = import ./landmines.nix { inherit lib; };
  realHost = import ./real-host.nix { inherit lib; };
  denTemplate = import ./den-template.nix { inherit lib; };
  floor = import ./floor.nix { inherit lib; };
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
  # realHost.mk needs nixpkgs at call time, so gate is declared (not derived from mk {}).
  realHost = {
    inherit (realHost) mk;
    defaultParams = {
      n = 5;
    };
    gate = "drvPath";
    tier = "both";
  };
  denTemplate = {
    inherit (denTemplate) mk;
    defaultParams = { }; # mk is called with denCorpus at the test site (Task 2), not with params
    gate = "drvPath";
    tier = "parity";
  };
  inherit floor;
}
// lib.mapAttrs (_: lm: {
  inherit (lm) mk;
  defaultParams = { };
  gate = (lm.mk { }).gate;
  tier = "parity";
}) landmines

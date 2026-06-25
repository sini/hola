{ hola, denFleet, ... }:
let
  inherit (hola) corpus adapter parity;
  bitstream = corpus.denFleet.mk {
    inherit (denFleet) nixConfig;
    host = "bitstream";
    channelInput = "nixpkgs-unstable";
  };
  nc = denFleet.nixConfig;
  vendored = ../../lib/engine/vendor/modules.nix;
in
{
  flake.tests.den-fleet-parity.bitstream = {
    expr =
      (parity.drvPathGate {
        a = adapter.runDenFleet (lib': lib') bitstream; # vanilla: identity → host's REAL build
        b = adapter.runDenFleet adapter.fleetEngineLib bitstream; # engine: vendored modules on the channel lib
      }).identical;
    expected = true;
  };
  flake.tests.channel-modules-identity.check = {
    expr =
      builtins.readFile vendored
      == builtins.readFile (nc.inputs.nixpkgs-unstable.outPath + "/lib/modules.nix")
      &&
        builtins.readFile vendored
        == builtins.readFile (nc.inputs.nixpkgs-master.outPath + "/lib/modules.nix");
    expected = true;
  };
}

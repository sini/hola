{ hola, denFleet, ... }:
let
  inherit (hola) corpus adapter parity;
  bitstream = corpus.denFleet.mk {
    inherit (denFleet) nixConfig;
    host = "bitstream";
    channelInput = "nixpkgs-unstable";
  };
  blade = corpus.denFleet.mk {
    inherit (denFleet) nixConfig;
    host = "blade";
    channelInput = "nixpkgs-master";
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
  flake.tests.den-fleet-parity.blade = {
    expr =
      (parity.drvPathGate {
        a = adapter.runDenFleet (lib': lib') blade; # vanilla: REAL blade build (…5e8ca42.drv)
        b = adapter.runDenFleet adapter.fleetEngineLib blade; # engine on the master channel lib
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

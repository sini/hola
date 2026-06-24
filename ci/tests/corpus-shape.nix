{ hola, nixpkgs, ... }:
let
  rh = hola.corpus.realHost.mk { inherit nixpkgs; };
in
{
  flake.tests.corpus = {
    realHost-shape = {
      expr =
        (rh.gate == "drvPath")
        && (builtins.isList rh.modules)
        && (rh ? evalConfig)
        && (rh.class == "nixos");
      expected = true;
    };
    floor-present = {
      expr = builtins.all (k: hola.corpus.floor ? ${k}) [
        "justImport"
        "libOnly"
        "modScale"
      ];
      expected = true;
    };
  };
}

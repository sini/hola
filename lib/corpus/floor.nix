{ lib }:
{
  # bench_just_import: force the package-set attrNames count (the H1 //-storm floor)
  justImport = {
    tier = "perf";
    expr =
      { nixpkgs }:
      builtins.length (
        builtins.attrNames (
          import nixpkgs {
            config = { };
            overlays = [ ];
          }
        )
      );
  };
  # bench_lib_only: lib alone, no package set
  libOnly = {
    tier = "perf";
    expr = { nixpkgs }: (import (nixpkgs + "/lib")).version;
  };
  # bench_mod_scale: 200-module package-free evalModules
  modScale = {
    tier = "perf";
    expr =
      { ... }:
      let
        mkMod = n: {
          config.env = builtins.listToAttrs (
            map (i: {
              name = "k${toString n}_${toString i}";
              value = i;
            }) (lib.range 1 50)
          );
        };
        res = lib.evalModules {
          modules = [
            {
              options.env = lib.mkOption {
                type = lib.types.attrsOf lib.types.int;
                default = { };
              };
            }
          ]
          ++ map mkMod (lib.range 1 200);
        };
      in
      builtins.length (builtins.attrNames res.config.env);
  };
}

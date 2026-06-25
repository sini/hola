{ lib }:
let
  engineConcern = import ./engine { inherit lib; };

  engines = {
    # Each engine carries its lib AND evalModules so the host tier (runHost) can thread the
    # engine's possibly-extended lib into eval-config.
    vanilla = {
      lib = lib;
      evalModules = lib.evalModules;
    };
    # identity: lib.extend passthrough — byte-identical output, routes through the SAME override
    # seam the engine arm will later replace (submodule extendModules bypass, §4 HC5).
    identity =
      let
        elib = lib.extend (
          final: prev: {
            modules = prev.modules // {
              evalModules = a: prev.modules.evalModules a;
            };
          }
        );
      in
      {
        lib = elib;
        evalModules = elib.evalModules;
      };
    # engine: the vendored-body seam — mkEngine overrides `final.modules` ALONE (lib/engine), so
    # the whole module surface (evalModules/mkIf/…) routes through the owned copy via the fixpoint.
    engine = engineConcern.engine;
  };

  # value / synthetic / landmine tier:
  run =
    engine: fx:
    engine.evalModules (
      {
        inherit (fx) modules;
        specialArgs = fx.specialArgs or { };
      }
      // (if (fx.class or null) == null then { } else { inherit (fx) class; })
    );

  # host tier (gate="drvPath"): dual-run through eval-config, threading the engine's lib so the
  # override reaches the host evaluator (eval-config builds its evaluator from its `lib` arg).
  runHost =
    engine: fx:
    import fx.evalConfig {
      inherit (engine) lib;
      system = "x86_64-linux";
      modules = fx.modules;
    };

  # Den-template tier (gate="drvPath"): invoke the template's RAW outputs with inputs.nixpkgs.lib
  # doctored to the engine's lib (full-surface), return the host NixOS eval result.
  runDenTemplate =
    engine: fx:
    let
      t = fx.denTemplate;
      raw = import (t.den.outPath + "/templates/${t.template}/flake.nix");
      out = raw.outputs {
        nixpkgs = t.nixpkgsFlake // {
          lib = engine.lib;
        };
        import-tree = t.importTree;
        den = t.den;
      };
    in
    t.hostOf out;
in
{
  inherit
    engines
    run
    runHost
    runDenTemplate
    ;
}

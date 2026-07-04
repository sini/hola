{ hola, ... }:
let
  inherit (hola.adapter) run engines compositionWalk;
  fx = {
    modules = [ ({ lib, ... }: { options.x = lib.mkOption { default = 1; }; }) ];
  };
in
{
  flake.tests.adapter = {
    run-no-throw = {
      expr = (run engines.vanilla fx).config.x;
      expected = 1;
    };
    identity-byte-identical = {
      expr = (run engines.vanilla fx).config == (run engines.identity fx).config;
      expected = true;
    };
    # compositionWalk prunes option (`_type`) and derivation nodes at WHNF — the throwing leaves below
    # must never be forced, so the walk both terminates and returns the top-level names.
    composition-walk-prunes = {
      expr = compositionWalk {
        opt = {
          _type = "option";
          value = throw "must not force option leaf";
        };
        drv = {
          type = "derivation";
          drvPath = throw "must not force drvPath";
        };
      };
      expected = [
        "drv"
        "opt"
      ];
    };
  };
}

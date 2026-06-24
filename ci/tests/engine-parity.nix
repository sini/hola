{ hola, ... }:
let
  inherit (hola) adapter corpus;
in
{
  flake.tests.engine-smoke.check = {
    expr =
      let
        r = adapter.run adapter.engines.engine (corpus.synthetic.mk { });
      in
      builtins.isAttrs r.config
      && (adapter.engines.engine ? lib)
      && (adapter.engines.engine ? evalModules);
    expected = true;
  };
}

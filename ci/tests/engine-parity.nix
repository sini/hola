{ hola, nixpkgs, ... }:
let
  inherit (hola)
    corpus
    compose
    adapter
    engine
    ;
  parityFixtures = {
    synthetic = corpus.synthetic.mk { };
    priorityFold = corpus.priorityFold.mk { };
    order = corpus.order.mk { };
    valueMeta = corpus.valueMeta.mk { };
    latticeThrows = corpus.latticeThrows.mk { };
    realHost = corpus.realHost.mk {
      inherit nixpkgs;
      n = 3;
    };
  };
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
  flake.tests.engine-parity = builtins.mapAttrs (_: fx: {
    expr = compose.engineParity fx;
    expected = true;
  }) parityFixtures;
  flake.tests.non-vacuity.check = {
    expr = compose.valueEq adapter.engines.vanilla engine._brokenProbe (corpus.valueMeta.mk { });
    expected = false;
  };
}

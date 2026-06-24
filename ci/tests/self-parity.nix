{ hola, nixpkgs, ... }:
let
  inherit (hola) corpus compose;
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
  flake.tests.self-parity = builtins.mapAttrs (_: fx: {
    expr = compose.selfParity fx;
    expected = true;
  }) parityFixtures;
}

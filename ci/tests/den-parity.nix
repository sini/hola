{ hola, denCorpus, ... }:
let
  inherit (hola) corpus adapter parity;
  fx = corpus.denTemplate.mk denCorpus;
in
{
  flake.tests.den-parity.den-template = {
    expr =
      (parity.drvPathGate {
        a = adapter.runDenTemplate adapter.engines.vanilla fx;
        b = adapter.runDenTemplate adapter.engines.engine fx;
      }).identical;
    expected = true;
  };
}

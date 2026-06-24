{ hola, ... }:
let
  inherit (hola) parity corpus;
  inherit (hola.adapter) run engines;
  vrun = fx: run engines.vanilla fx;
in
{
  flake.tests.landmines =
    let
      pf = corpus.priorityFold.mk { };
      od = corpus.order.mk { };
      vm = corpus.valueMeta.mk { };
      lt = corpus.latticeThrows.mk { };
    in
    {
      priorityFold = {
        expr = pf.pick (vrun pf);
        expected = pf.expected;
      };
      order = {
        expr = od.pick (vrun od);
        expected = od.expected;
      };
      valueMeta = {
        expr = vm.pick (vrun vm);
        expected = vm.expected;
      };
      latticeThrows = {
        expr = parity.expectThrow (lt.pick (vrun lt));
        expected = true;
      };
    };
}

{
  lib,
  parity,
  adapter,
  corpus,
}:
let
  inherit (adapter) run runHost engines;
  pickOf = fx: fx.pick or (r: r.config); # picks receive the full eval RESULT
  valueEq =
    e1: e2: fx:
    (parity.diff {
      a = pickOf fx (run e1 fx);
      b = pickOf fx (run e2 fx);
    }).identical;
  drvEq =
    e1: e2: fx:
    (parity.drvPathGate {
      a = runHost e1 fx;
      b = runHost e2 fx;
    }).identical;
  expectThrowFx = engine: fx: parity.expectThrow (pickOf fx (run engine fx)); # §6 engine:fx signature
  selfParity =
    fx:
    if (fx.gate or "value") == "throws" then
      (expectThrowFx engines.vanilla fx) && (expectThrowFx engines.identity fx)
    else if (fx.gate or "value") == "drvPath" then
      drvEq engines.vanilla engines.identity fx
    else
      valueEq engines.vanilla engines.identity fx;
in
{
  inherit
    valueEq
    drvEq
    expectThrowFx
    selfParity
    ;
}

{ lib }:
let
  inherit (builtins)
    isAttrs
    isList
    attrNames
    tryEval
    deepSeq
    length
    elemAt
    head
    ;

  force = x: deepSeq x x;

  diffAt =
    path: a: b:
    if isAttrs a && isAttrs b then
      let
        keys = lib.unique (attrNames a ++ attrNames b);
      in
      lib.concatMap (
        k:
        if (a ? ${k}) && (b ? ${k}) then
          diffAt (path ++ [ k ]) a.${k} b.${k}
        else
          [
            {
              path = path ++ [ k ];
              aValue = if a ? ${k} then a.${k} else "__absent";
              bValue = if b ? ${k} then b.${k} else "__absent";
            }
          ]
      ) keys
    else if isList a && isList b then
      if length a != length b then
        [
          {
            path = path ++ [ "length" ];
            aValue = length a;
            bValue = length b;
          }
        ]
      else
        lib.concatMap (i: diffAt (path ++ [ i ]) (elemAt a i) (elemAt b i)) (lib.range 0 (length a - 1))
    else if a == b then
      [ ]
    else
      [
        {
          inherit path;
          aValue = a;
          bValue = b;
        }
      ];

  diff =
    { a, b }:
    let
      ea = tryEval (force a);
      eb = tryEval (force b);
    in
    if ea.success && eb.success then
      let
        divs = diffAt [ ] ea.value eb.value;
      in
      {
        identical = divs == [ ];
        divergences = divs;
      }
    else
      {
        identical = false;
        divergences = [
          {
            path = [ ];
            aValue = if ea.success then ea.value else "<<throw>>";
            bValue = if eb.success then eb.value else "<<throw>>";
          }
        ];
      };

  locate =
    { a, b }:
    let
      d = diff { inherit a b; };
    in
    if d.identical then null else head d.divergences;

  drvPathGate =
    { a, b }:
    let
      ea = tryEval a.config.system.build.toplevel.drvPath;
      eb = tryEval b.config.system.build.toplevel.drvPath;
    in
    if ea.success && eb.success then
      {
        identical = ea.value == eb.value;
        aDrv = ea.value;
        bDrv = eb.value;
      }
    else
      {
        identical = false;
        aDrv = if ea.success then ea.value else "<<throw>>";
        bDrv = if eb.success then eb.value else "<<throw>>";
      };

  # `projection` = an already-picked value; the engine:fx wrapper lives in compose.nix (Task 7, §6).
  expectThrow = projection: !(tryEval (force projection)).success;

  # pick-builder: augments a base pick with option-shape data.
  # NOTE: getSubOptions (and result.options) always carry the synthetic `_module`
  # pseudo-option — filter it so the surface is the real option names only.
  withOptionShape =
    {
      basePick ? (_: { }),
      options ? null,
      subOptionPaths ? { },
    }:
    result:
    let
      dropModule = builtins.filter (n: n != "_module");
    in
    (basePick result)
    // {
      __optionNames = if options != null then options else dropModule (attrNames result.options);
      __subOptions = lib.mapAttrs (
        opt: loc: dropModule (attrNames (result.options.${opt}.type.getSubOptions loc))
      ) subOptionPaths;
    };
in
{
  inherit
    force
    diffAt
    diff
    locate
    drvPathGate
    expectThrow
    withOptionShape
    ;
}

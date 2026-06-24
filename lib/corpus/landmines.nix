{ lib }:
let
  inherit (lib)
    mkForce
    mkDefault
    mkIf
    mkOrder
    mkBefore
    mkAfter
    ;
  # value-tier list landmine builder
  mkList =
    {
      elemType,
      defs,
      expected,
    }:
    {
      gate = "value";
      pick = e: e.config.thing;
      inherit expected;
      modules = [
        {
          options.thing = lib.mkOption {
            type = lib.types.listOf elemType;
            default = [ ];
          };
        }
      ]
      ++ defs;
    };
in
{
  # hc3_l1 L1: priority fold — mkForce (prio 50) is the winning class -> ["c"]
  priorityFold.mk =
    _:
    mkList {
      elemType = lib.types.str;
      defs = [
        { config.thing = [ "n" ]; }
        { config.thing = mkForce [ "c" ]; }
        { config.thing = mkDefault [ "z" ]; }
        { config.thing = mkIf false [ "gone" ]; }
        { config.thing = mkOrder 10 [ "ord" ]; }
      ];
      expected = [ "c" ];
    };
  # hc3_l1 L2: order — mkBefore < normal < mkAfter
  order.mk =
    _:
    mkList {
      elemType = lib.types.str;
      defs = [
        { config.thing = mkAfter [ "last" ]; }
        { config.thing = [ "mid" ]; }
        { config.thing = mkBefore [ "first" ]; }
      ];
      expected = [
        "first"
        "mid"
        "last"
      ];
    };
  # hc3_meta: plain listOf-int, two same-priority same-order defs.
  # SURPRISE (empirically verified across 3 nixpkgs incl. hc3_meta's own checkout): same-priority
  # same-order listOf defs merge in REVERSE declaration order, so [1] then [2] -> [2 1] (NOT [1 2]).
  # This is exactly the non-obvious merge behavior the parity contract exists to pin.
  # (value tier; the opt.valueMeta options-surface probe is an engine-increment concern)
  valueMeta.mk =
    _:
    mkList {
      elemType = lib.types.int;
      defs = [
        { config.thing = [ 1 ]; }
        { config.thing = [ 2 ]; }
      ];
      expected = [
        2
        1
      ];
    };
  # hc3_lattice: two same-priority mkForce on int -> merge conflict throws
  latticeThrows.mk = _: {
    gate = "throws";
    pick = e: e.config.n;
    modules = [
      { options.n = lib.mkOption { type = lib.types.int; }; }
      { config.n = mkForce 1; }
      { config.n = mkForce 2; }
    ];
  };
}

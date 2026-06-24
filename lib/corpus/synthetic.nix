{ lib }:
{
  mk =
    {
      n ? 50,
      ndecls ? 20,
      layers ? 2,
    }:
    let
      optNames = map (i: "o${toString i}") (lib.range 1 ndecls);
      sub = lib.types.submodule {
        options = lib.genAttrs optNames (
          _:
          lib.mkOption {
            type = lib.types.str;
            default = "";
          }
        );
      };
      # o1 is an mkMerge of `layers` priority contributions (exercises filterOverrides / the fold).
      elemVal = lib.mkMerge (
        map (l: { o1 = lib.mkOverride (100 - l) "v${toString l}"; }) (lib.range 1 layers)
      );
    in
    {
      gate = "value";
      pick = e: e.config.things;
      modules = [
        {
          options.things = lib.mkOption {
            type = lib.types.attrsOf sub;
            default = { };
          };
        }
        { config.things = lib.genAttrs (map (e: "e${toString e}") (lib.range 1 n)) (_: elemVal); }
      ];
    };
}

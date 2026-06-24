{ lib }:
let
  # mkEngine: BE lib.modules.evalModules by overriding `final.modules` with a vendored body.
  # Overriding `modules` ALONE suffices — lib/default.nix re-exports the whole module surface via
  # `inherit (self.modules)`, so evalModules/mkIf/mkMerge/mkOverride/filterOverrides/… all resolve
  # to the vendored copy through the fixpoint. `final.types` is re-fixpointed against `final`, so
  # submoduleWith reaches the vendored evalModules at `base`; the vendored file-local extendModules
  # keeps every submodule re-entry inside the owned body (E1 spec §3 / HC5).
  mkEngine =
    modulesFile:
    let
      holaLib = lib.extend (
        final: _prev: {
          modules = import modulesFile { lib = final; };
        }
      );
    in
    {
      lib = holaLib;
      evalModules = holaLib.evalModules;
    };
in
{
  inherit mkEngine;
  engine = mkEngine ./vendor/modules.nix;
}

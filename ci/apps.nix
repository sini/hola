# Tier-2 evidence apps (flake apps via the gen mkCi `extraModules` seam).
#
# These are EVIDENCE tooling — they NEVER gate CI. They measure the vanilla
# baseline (no engine arm exists yet). Each bench script is baked with:
#   HOLA_SRC  — the hola repo root (copied to the store at build time)
#   NIXPKGS   — the ci flake's pinned nixpkgs source tree (for a package-free
#               `import (NIXPKGS + "/lib")` and the H1 //-storm floor)
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      holaSrc = ../.; # hola repo root
      nixpkgsSrc = inputs.nixpkgs; # ci flake's pinned nixpkgs (package-free lib path + floor)
      # extraEnv: name→value strings baked as `export name="value"` after the two common vars, for
      # scripts that need more baked context (fleet-stats bakes the pinned nix-config store path).
      mkBench =
        name: extraInputs: extraEnv: scriptFile:
        let
          envLines = pkgs.lib.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') extraEnv
          );
          app = pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [
              pkgs.nix
              pkgs.jq
            ]
            ++ extraInputs;
            text = ''
              export HOLA_SRC="${holaSrc}"
              export NIXPKGS="${nixpkgsSrc}"
              ${envLines}
              ${builtins.readFile scriptFile}
            '';
          };
        in
        {
          type = "app";
          program = "${app}/bin/${name}";
        };
    in
    {
      apps.stat-capture = mkBench "stat-capture" [ ] { } ./bench/stat-capture.sh;
      apps.scaling-curve = mkBench "scaling-curve" [ ] { } ./bench/scaling-curve.sh;
      apps.floor-decomp = mkBench "floor-decomp" [ ] { } ./bench/floor-decomp.sh;
      apps.parity-report = mkBench "parity-report" [ pkgs.hyperfine ] { } ./bench/parity-report.sh;
      apps.vendor-check = mkBench "vendor-check" [ ] { } ./bench/vendor-check.sh;
      # Fleet tier: bakes the ci-pinned nix-config source (getFlake'd back to a flake value in the
      # driver — the shell equivalent of the parity test's specialArgs `denFleet.nixConfig`).
      apps.fleet-stats = mkBench "fleet-stats" [ ] {
        HOLA_FLEET_NIXCONFIG = "${inputs.nix-config}";
      } ./bench/fleet-stats.sh;
      # Task 8 regression gate: re-asserts the campaign's parity + savings baselines. UNLIKE the other
      # Tier-2 apps this one DOES gate (the CI workflow's fleet-gates job runs it). It re-invokes
      # `nix run .#fleet-stats` + class-share-realization.sh for the [ci-remeasure] partition, so it also
      # bakes the pinned nix-config (for symmetry) though its consistency partition needs only HOLA_SRC.
      apps.fleet-gates = mkBench "fleet-gates" [ ] {
        HOLA_FLEET_NIXCONFIG = "${inputs.nix-config}";
      } ./bench/fleet-gates.sh;
    };
}

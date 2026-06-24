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
      mkBench =
        name: extraInputs: scriptFile:
        let
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
      apps.stat-capture = mkBench "stat-capture" [ ] ./bench/stat-capture.sh;
      apps.scaling-curve = mkBench "scaling-curve" [ ] ./bench/scaling-curve.sh;
      apps.floor-decomp = mkBench "floor-decomp" [ ] ./bench/floor-decomp.sh;
      apps.parity-report = mkBench "parity-report" [ pkgs.hyperfine ] ./bench/parity-report.sh;
      apps.vendor-check = mkBench "vendor-check" [ ] ./bench/vendor-check.sh;
    };
}

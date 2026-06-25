{
  inputs = {
    gen.url = "github:sini/gen";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    den.url = "github:denful/den";
    import-tree.url = "github:vic/import-tree";
    nix-config.url = "github:sini/nix-config";
  };
  outputs =
    inputs@{ gen, nixpkgs, ... }:
    let
      hola = import ../. { lib = nixpkgs.lib; };
    in
    gen.lib.mkCi {
      inherit inputs;
      name = "hola";
      testModules = ./tests;
      # Tier-2 evidence apps (perSystem.apps) — never gate CI.
      extraModules = [ ./apps.nix ];
      # nixpkgs threaded for the real-host fixture (eval-config import) in later tasks.
      specialArgs = {
        inherit hola;
        nixpkgs = nixpkgs.outPath or nixpkgs; # outPath string for the realHost fixture
        # E2a: the Den-template corpus needs the nixpkgs FLAKE (for .lib / nixosSystem) + den + import-tree
        denCorpus = {
          inherit (inputs) den;
          importTree = inputs.import-tree;
          nixpkgsFlake = nixpkgs;
        };
        denFleet = {
          nixConfig = inputs.nix-config;
        };
      };
    };
}

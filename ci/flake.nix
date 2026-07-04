{
  nixConfig = {
    extra-experimental-features = [
      "pipe-operators"
      "pipe-operator"
    ];
  };
  inputs = {
    gen.url = "github:sini/gen";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    den.url = "github:denful/den";
    import-tree.url = "github:vic/import-tree";
    nix-config.url = "github:sini/nix-config";
    # Arm R (rebuild-dedup, Task 7): the incremental rebuilder. Locked for provenance; the measured
    # arm expr getFlakes the pinned rev (7a87691) inline (self-contained, --impure), so the lock and
    # the arm's pin must agree (MEASUREMENT.md §rebuild-dedup). nixpkgs-lib-free — no nixpkgs input.
    gen-rebuild.url = "github:sini/gen-rebuild/7a87691f004679668852d53fc130a57bc305e20a";
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

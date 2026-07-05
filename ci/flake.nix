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
    # Arm R (rebuild-dedup, Task 7): the incremental rebuilder. AUTHORITATIVE pin = the getFlake rev
    # INSIDE the rebuild-dedup arm expr (ci/bench/arms.json); THIS input is provenance-only (locking +
    # `nix flake` visibility) — the measured run getFlakes its own rev under --impure and never reads
    # this input. So bump BOTH sites or NEITHER (same dual-site rule as the den-s2 rev, pinned only in
    # the class-share arm expr). nixpkgs-lib-free — no nixpkgs input.
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
      # Tier-2 evidence apps (perSystem.apps) — mostly non-gating; fleet-gates (Task 8) DOES gate.
      # The stack-raising nix-unit hook wrapper now comes from gen's mkCi itself (flakeModule.nix,
      # since gen@6d259ef) — the local precommit.nix override it superseded is deleted.
      extraModules = [
        ./apps.nix
      ];
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

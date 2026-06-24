{
  inputs = {
    gen.url = "github:sini/gen";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
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
      # nixpkgs threaded for the real-host fixture (eval-config import) in later tasks.
      specialArgs = {
        inherit hola;
        nixpkgs = nixpkgs.outPath or nixpkgs;
      };
    };
}

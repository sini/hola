{
  description = "hola: parity harness for a pure-gen module engine hosting unmodified nixpkgs modules";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { nixpkgs, ... }:
    {
      lib = import ./. { lib = nixpkgs.lib; };
      __functor = _: import ./.;
    };
}

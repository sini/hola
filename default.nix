{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:
import ./lib { inherit lib; }

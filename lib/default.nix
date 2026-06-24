{ lib }:
let
  args = { inherit lib; };
  parity = import ./parity.nix args;
  adapter = import ./adapter.nix args;
  corpus = import ./corpus args;
  compose = import ./compose.nix (args // { inherit parity adapter corpus; });
in
{
  inherit
    parity
    adapter
    corpus
    compose
    ;
}
// compose

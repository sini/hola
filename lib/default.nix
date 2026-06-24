{ lib }:
let
  args = { inherit lib; };
  parity = import ./parity.nix args;
  engine = import ./engine args;
  adapter = import ./adapter.nix args;
  corpus = import ./corpus args;
  compose = import ./compose.nix (args // { inherit parity adapter corpus; });
in
{
  inherit
    parity
    engine
    adapter
    corpus
    compose
    ;
}

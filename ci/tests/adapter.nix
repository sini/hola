{ hola, ... }:
let
  inherit (hola.adapter) run engines;
  fx = {
    modules = [ ({ lib, ... }: { options.x = lib.mkOption { default = 1; }; }) ];
  };
in
{
  flake.tests.adapter = {
    run-no-throw = {
      expr = (run engines.vanilla fx).config.x;
      expected = 1;
    };
    identity-byte-identical = {
      expr = (run engines.vanilla fx).config == (run engines.identity fx).config;
      expected = true;
    };
  };
}

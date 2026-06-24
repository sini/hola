{ hola, inputs, ... }:
let
  p = hola.parity;
  lib = inputs.nixpkgs.lib;
  mockA = {
    config.system.build.toplevel.drvPath = "/nix/store/aaa";
  };
  mockB = {
    config.system.build.toplevel.drvPath = "/nix/store/bbb";
  };
  optResult = lib.evalModules {
    modules = [
      {
        options.svc = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.port = lib.mkOption {
                type = lib.types.int;
                default = 0;
              };
            }
          );
          default = { };
        };
      }
    ];
  };
  picked = p.withOptionShape {
    subOptionPaths = {
      svc = [
        "svc"
        "*"
      ];
    };
  } optResult;
in
{
  flake.tests.oracle = {
    equal = {
      expr =
        (p.diff {
          a = {
            x = 1;
          };
          b = {
            x = 1;
          };
        }).identical;
      expected = true;
    };
    differ-scalar = {
      expr =
        (p.diff {
          a = {
            x = 1;
          };
          b = {
            x = 2;
          };
        }).divergences;
      expected = [
        {
          path = [ "x" ];
          aValue = 1;
          bValue = 2;
        }
      ];
    };
    missing-key = {
      expr =
        (p.diff {
          a = {
            x = 1;
          };
          b = { };
        }).divergences;
      expected = [
        {
          path = [ "x" ];
          aValue = 1;
          bValue = "__absent";
        }
      ];
    };
    list-order = {
      expr =
        (p.diff {
          a = [
            "a"
            "b"
          ];
          b = [
            "b"
            "a"
          ];
        }).identical;
      expected = false;
    };
    list-length = {
      expr =
        (p.diff {
          a = [ "a" ];
          b = [
            "a"
            "b"
          ];
        }).divergences;
      expected = [
        {
          path = [ "length" ];
          aValue = 1;
          bValue = 2;
        }
      ];
    };
    nested = {
      expr =
        (p.diff {
          a = {
            s = {
              y = [ 1 ];
            };
          };
          b = {
            s = {
              y = [ 2 ];
            };
          };
        }).divergences;
      expected = [
        {
          path = [
            "s"
            "y"
            0
          ];
          aValue = 1;
          bValue = 2;
        }
      ];
    };
    one-arm-throw = {
      expr =
        (p.diff {
          a = {
            x = 1;
          };
          b = (throw "boom");
        }).identical;
      expected = false;
    };
    locate-head = {
      expr =
        (p.locate {
          a = {
            x = 1;
          };
          b = {
            x = 2;
          };
        }).path;
      expected = [ "x" ];
    };
    drvPathGate-equal = {
      expr =
        (p.drvPathGate {
          a = mockA;
          b = mockA;
        }).identical;
      expected = true;
    };
    drvPathGate-differ = {
      expr =
        (p.drvPathGate {
          a = mockA;
          b = mockB;
        }).identical;
      expected = false;
    };
    expectThrow-throws = {
      expr = p.expectThrow (throw "x");
      expected = true;
    };
    expectThrow-clean = {
      expr = p.expectThrow 1;
      expected = false;
    };
    withOptionShape-subopts = {
      expr = picked.__subOptions.svc;
      expected = [ "port" ];
    };
    withOptionShape-names = {
      expr = builtins.elem "svc" picked.__optionNames;
      expected = true;
    };
  };
}

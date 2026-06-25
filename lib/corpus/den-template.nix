{ lib }:
{
  # mk: build the Den-template parity fixture. `denCorpus` = { den; importTree; nixpkgsFlake; }
  # (threaded from ci/flake.nix specialArgs).
  mk =
    {
      den,
      importTree,
      nixpkgsFlake,
      template ? "minimal",
      # per-template accessor: where the host NixOS eval result lands in the template's `.config.flake`.
      hostOf ? (out: out.nixosConfigurations.igloo),
    }:
    {
      gate = "drvPath";
      # data the runDenTemplate adapter consumes (it does the engine-lib doctoring):
      denTemplate = {
        inherit
          den
          importTree
          nixpkgsFlake
          template
          hostOf
          ;
      };
    };
}

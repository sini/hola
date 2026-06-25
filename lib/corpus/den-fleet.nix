{ lib }:
{
  # channelInput = the nixpkgs INPUT NAME to doctor ("nixpkgs-unstable" | "nixpkgs-master"), DISTINCT
  # from the den `channel` name (bitstream's den channel is "nixos-unstable", its input is "nixpkgs-unstable").
  mk =
    {
      nixConfig,
      host,
      channelInput,
    }:
    {
      gate = "drvPath";
      denFleet = { inherit nixConfig host channelInput; };
    };
}

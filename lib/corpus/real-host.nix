{ lib }:
{
  mk =
    {
      nixpkgs,
      n ? 5,
    }:
    {
      class = "nixos";
      gate = "drvPath";
      evalConfig = nixpkgs + "/nixos/lib/eval-config.nix";
      # host modules; dual-run through eval-config via compose.runHost (Task 7, threads engine.lib).
      modules = [
        {
          config = {
            networking.hostName = "parity";
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "x";
              fsType = "ext4";
            }; # fsType REQUIRED or eval-config throws
            system.stateVersion = "24.05";
          };
        }
        {
          config.systemd.services = lib.genAttrs (map (i: "svc${toString i}") (lib.range 1 n)) (_: {
            script = "true";
            wantedBy = [ "multi-user.target" ];
          });
        }
      ];
    };
}

{ config, flake, lib, pkgs, ... }:

let
  cfg = config.programs."opencode-sandbox";
in
{
  options.programs."opencode-sandbox" = {
    enable = lib.mkEnableOption "the opencode sandbox launcher";

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Additional guest NixOS modules to include in the opencode sandbox VM.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (flake.packages.${pkgs.stdenv.hostPlatform.system}.opencode-sandbox.override {
        extraModules = cfg.extraModules;
      })
    ];
  };
}

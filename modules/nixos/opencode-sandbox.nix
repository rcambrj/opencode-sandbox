{ config, flake, lib, pkgs, ... }:

let
  cfg = config.programs."opencode-sandbox";

  pkg = flake.packages.${pkgs.stdenv.hostPlatform.system}.opencode-sandbox;
in
{
  options.programs."opencode-sandbox" = {
    enable = lib.mkEnableOption "the opencode sandbox launcher";

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Additional guest NixOS modules to include in the opencode sandbox VM.";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to an env file sourced inside the sandbox VM before opencode starts.";
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = pkg.emptyConfigDir;
      defaultText = lib.literalExpression "opencode-sandbox.emptyConfigDir";
      description = ''
        Host directory mounted at ~/.config/opencode inside the VM via overlayfs.
        Writes inside the VM are ephemeral (tmpfs overlay) and do not modify the host directory.
        Defaults to an empty directory.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "opencode-sandbox" ''
        exec ${lib.getExe (pkg.override {
          inherit (cfg) configDir;
          extraModules = cfg.extraModules;
        })} ${lib.optionalString (cfg.envFile != null) "--env-file ${toString cfg.envFile}"} "$@"
      '')
    ];
  };
}
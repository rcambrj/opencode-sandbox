{ flake, ... }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs."claude-sandbox";

  pkgsFor = flake.mkPackagesFor pkgs;
  pkg = pkgsFor.claude-sandbox;
in
{
  options.programs."claude-sandbox" = {
    enable = lib.mkEnableOption "the claude sandbox launcher";

    extraModules = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.attrs lib.types.unspecified);
      default = [ ];
      description = ''
        Additional guest NixOS modules to include in the claude sandbox VM.

        Each entry can be:
        - An attrset (a plain NixOS module): `{ ... }`
        - A function that receives sandbox arguments and returns an attrset: `args: { ... }`
          (for example: `({ guestPkgs, ... }: { ... })`)
      '';
    };

    showBootLogs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show guest kernel and systemd boot logs on the sandbox console.";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to an env file sourced inside the sandbox VM before claude starts.";
    };

    configDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Required host directory mounted inside the VM and exposed to claude via CLAUDE_CONFIG_DIR.
        The directory must be writable by the sandbox launcher.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Custom claude-sandbox package to use. When null, uses the flake's built package
        with extraModules and showBootLogs applied. When set, this package is used as-is.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configDir != null;
        message = "programs.claude-sandbox.configDir must be set to a writable host directory";
      }
    ];

    environment.systemPackages = [
      (flake.lib.mkWrappedExec {
        inherit pkgs;
        name = "claude-sandbox";
        package = if cfg.package != null then cfg.package else pkg.override {
          extraModules = cfg.extraModules;
          showBootLogs = cfg.showBootLogs;
        };
        flags = {
          env-file = cfg.envFile;
          config-dir = cfg.configDir;
        };
      })
    ];
  };
}

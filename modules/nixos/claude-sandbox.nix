{ flake, ... }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs."claude-sandbox";

  pkgsFor = flake.mkPackagesFor pkgs;
  pkg = pkgsFor.claude-sandbox;
in
{
  options.programs."claude-sandbox" =
    flake.lib.mkSandboxModuleOptions {
      enableDescription = "the claude sandbox launcher";
      packageDescription = ''
        Custom claude-sandbox package to use. When null, uses the flake's built package
        with extraModules and showBootLogs applied. When set, this package is used as-is.
      '';
    }
    // {

    configDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Required host directory mounted inside the VM and exposed to claude via CLAUDE_CONFIG_DIR.
        The directory must be writable by the sandbox launcher.
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
          expose-host-ports = lib.concatStringsSep "," (map builtins.toString cfg.exposeHostPorts);
        };
      })
    ];
  };
}

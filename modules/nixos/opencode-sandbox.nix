{ flake, ... }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs."opencode-sandbox";

  pkgsFor = flake.mkPackagesFor pkgs;
  pkg = pkgsFor.opencode-sandbox;
in
{
  options.programs."opencode-sandbox" = {
    enable = lib.mkEnableOption "the opencode sandbox launcher";

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Additional guest NixOS modules to include in the opencode sandbox VM.";
    };

    showBootLogs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show guest kernel and systemd boot logs on the sandbox console.";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to an env file sourced inside the sandbox VM before opencode starts.";
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = pkg.emptyDir;
      defaultText = lib.literalExpression "opencode-sandbox.emptyDir";
      description = ''
        Host directory mounted inside the VM and exposed to opencode via XDG_CONFIG_HOME.
        Defaults to an empty directory.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional host directory mounted inside the VM and exposed to opencode via XDG_DATA_HOME.

        opencode stores its main state in SQLite. Shared host filesystems used by QEMU VMs here rely on 9p,
        and virtiofs is not a general fix for SQLite WAL either. Those shared filesystems do not provide the
        locking and shared-memory behavior SQLite expects, so the sandbox defaults OPENCODE_DB to :memory:.

        If you want database-backed persistence anyway, you can opt in via env file with a SQLite URI such as
        `OPENCODE_DB=file:/mnt/opencode-sandbox/data/opencode.db?vfs=unix-excl`.

        Warning: `vfs=unix-excl` avoids the shared-memory WAL path, but it is only appropriate when exactly one
        sandbox instance uses that database path at a time. Concurrent instances pointed at the same database can
        fail or corrupt data.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional host directory mounted inside the VM and exposed to opencode via XDG_CACHE_HOME.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Custom opencode-sandbox package to use. When null, uses the flake's built package
        with extraModules and showBootLogs applied. When set, this package is used as-is.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (flake.lib.mkWrappedOpencodeSandbox {
        inherit pkgs;
        package = if cfg.package != null then cfg.package else pkg.override {
          extraModules = cfg.extraModules;
          showBootLogs = cfg.showBootLogs;
        };
        envFile = cfg.envFile;
        configDir = cfg.configDir;
        dataDir = cfg.dataDir;
        cacheDir = cfg.cacheDir;
      })
    ];
  };
}

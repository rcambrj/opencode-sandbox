{ config, flake, lib, pkgs, ... }:

let
  cfg = config.programs."opencode-sandbox";

  pkg = flake.packages.${pkgs.stdenv.hostPlatform.system}.opencode-sandbox;
  optionalFlag = name: value: lib.optionalString (value != null) "--${name} ${lib.escapeShellArg (toString value)}";
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
      default = pkg.emptyConfigDir;
      defaultText = lib.literalExpression "opencode-sandbox.emptyConfigDir";
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
        `OPENCODE_DB=file:/run/opencode-sandbox/data/opencode.db?vfs=unix-excl`.

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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "opencode-sandbox" ''
        exec ${lib.getExe (pkg.override {
          extraModules = cfg.extraModules;
          showBootLogs = cfg.showBootLogs;
        })} \
          ${optionalFlag "env-file" cfg.envFile} \
          ${optionalFlag "config-dir" cfg.configDir} \
          ${optionalFlag "data-dir" cfg.dataDir} \
          ${optionalFlag "cache-dir" cfg.cacheDir} \
          "$@"
      '')
    ];
  };
}

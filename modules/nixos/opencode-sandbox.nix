{ flake, ... }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs."opencode-sandbox";

  pkgsFor = flake.mkPackagesFor pkgs;
  pkg = pkgsFor.opencode-sandbox;

  moduleAssertions = flake.lib.mkSandboxModuleAssertions {
    optionPrefix = "programs.opencode-sandbox";
    package = cfg.package;
    ignoredWhenPackageSet = {
      extraModules = {
        value = cfg.extraModules;
        default = [ ];
      };
      showBootLogs = {
        value = cfg.showBootLogs;
        default = false;
      };
    };
  };
in
{
  options.programs."opencode-sandbox" =
    flake.lib.mkSandboxModuleOptions {
      enableDescription = "the opencode sandbox launcher";
      packageDescription = ''
        Custom opencode-sandbox package to use. When null, uses the flake's built package
        with extraModules and showBootLogs applied. When set, this package is used as-is.
      '';
    }
    // {

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

        When `exclusiveSqliteLock` is enabled and `dataDir` is set, the launcher uses
        `OPENCODE_DB=$dataDir/opencode.db` and manages a host lockfile.

        Shared host filesystems still do not provide the locking and shared-memory behavior SQLite expects.
        `vfs=unix-excl` avoids the shared-memory WAL path, but it is only appropriate when exactly one
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

    exclusiveSqliteLock = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Whether to enable the opencode exclusive SQLite lock behavior (`--exclusive-sqlite-lock=`).
        When enabled, the launcher creates an opencode lockfile and sets `OPENCODE_DB=$dataDir/opencode.db`.
        If a leftover lockfile is found, startup prompts for:
        continue with `:memory:` (`y`), abort (`n`), or adopt lockfile (`a`).

        This only works when `dataDir` is set; without `dataDir`, opencode continues with `OPENCODE_DB=:memory:`.

        Default `null` means the wrapper does not pass the flag and package defaults apply.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    warnings = moduleAssertions.warnings;

    environment.systemPackages = [
      (flake.lib.mkWrappedExec {
        inherit pkgs;
        name = "opencode-sandbox";
        package = if cfg.package != null then cfg.package else pkg.override {
          extraModules = cfg.extraModules;
          showBootLogs = cfg.showBootLogs;
        };
        flags = {
          env-file = cfg.envFile;
          config-dir = cfg.configDir;
          data-dir = cfg.dataDir;
          cache-dir = cfg.cacheDir;
          exclusive-sqlite-lock = cfg.exclusiveSqliteLock;
          expose-host-ports = lib.concatStringsSep "," (map builtins.toString cfg.exposeHostPorts);
        };
      })
    ];
  };
}

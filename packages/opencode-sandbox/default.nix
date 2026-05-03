{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkSandboxPackage {
  inherit pkgs system extraModules showBootLogs enableSshServer sshMaxAttempts;

  name = "opencode-sandbox";

  extraShares = [
    {
      tag = "opencode-config";
      sourceEnvVar = "AGENT_SANDBOX_CONFIG_DIR";
      mountPoint = "/mnt/agent-sandbox/config/opencode";
    }
    {
      tag = "opencode-data";
      sourceEnvVar = "AGENT_SANDBOX_DATA_DIR";
      mountPoint = "/mnt/agent-sandbox/data/opencode";
      markerFile = "/mnt/agent-sandbox/control/opencode-has-data-dir";
    }
    {
      tag = "opencode-cache";
      sourceEnvVar = "AGENT_SANDBOX_CACHE_DIR";
      mountPoint = "/mnt/agent-sandbox/cache/opencode";
      markerFile = "/mnt/agent-sandbox/control/opencode-has-cache-dir";
    }
  ];

  guestModules = [
    {
      microvm.mem = pkgs.lib.mkDefault 1024;
      systemd.tmpfiles.rules = [
        "d /mnt/agent-sandbox/config 0755 root root -"
        "d /mnt/agent-sandbox/data 0755 root root -"
        "d /mnt/agent-sandbox/cache 0755 root root -"
      ];
    }
  ];

  launcherScript = flake.lib.mkLauncherScript {
    sessionCommand = { guestSystem, pkgs, ... }: pkgs.writeShellScriptBin "opencode-wrapper" ''
      export OPENCODE_DB=:memory:

      if [ -r /mnt/agent-sandbox/control/opencode-use-exclusive-sqlite-lock ]; then
        export OPENCODE_DB='file:/mnt/agent-sandbox/data/opencode.db?vfs=unix-excl'
      fi

      export XDG_CONFIG_HOME=/mnt/agent-sandbox/config

      if [ -r /mnt/agent-sandbox/control/opencode-has-data-dir ]; then
        export XDG_DATA_HOME=/mnt/agent-sandbox/data
      fi

      if [ -r /mnt/agent-sandbox/control/opencode-has-cache-dir ]; then
        export XDG_CACHE_HOME=/mnt/agent-sandbox/cache
      fi

      exec ${pkgs.lib.getExe inputs.numtide-llm-agents.packages.${guestSystem}.opencode} "$@"
    '';
    extraFlags = {
      config-dir = "config_dir";
      data-dir = "data_dir";
      cache-dir = "cache_dir";
      exclusive-sqlite-lock = "exclusive_sqlite_lock";
    };
    extraFinalize = { coreutils, name, emptyDir, ... }: ''
      has_data_dir=0
      has_cache_dir=0
      use_exclusive_sqlite_lock=1

      config_dir="''${config_dir-${emptyDir}}"
      data_dir="''${data_dir-${emptyDir}}"
      cache_dir="''${cache_dir-${emptyDir}}"
      exclusive_sqlite_lock="''${exclusive_sqlite_lock-true}"

      case "$exclusive_sqlite_lock" in
        true|1)
          use_exclusive_sqlite_lock=1
          ;;
        false|0)
          use_exclusive_sqlite_lock=0
          ;;
        *)
          printf '${name}: --exclusive-sqlite-lock must be true or false, got: %s\n' "$exclusive_sqlite_lock" >&2
          exit 2
          ;;
      esac

      if [ "$config_dir" = "${emptyDir}" ]; then
        config_dir="$control_dir/opencode-config"
        mkdir -p "$config_dir"
      fi

      config_dir="$(${coreutils}/bin/realpath "$config_dir")"

      if [ ! -d "$config_dir" ]; then
        printf '${name}: config directory not found: %s\n' "$config_dir" >&2
        exit 1
      fi

      if [ "$data_dir" != "${emptyDir}" ]; then
        has_data_dir=1
        data_dir="$(${coreutils}/bin/realpath "$data_dir")"
        if [ ! -d "$data_dir" ]; then
          printf '${name}: data directory not found: %s\n' "$data_dir" >&2
          exit 1
        fi
      fi

      if [ "$cache_dir" != "${emptyDir}" ]; then
        has_cache_dir=1
        cache_dir="$(${coreutils}/bin/realpath "$cache_dir")"
        if [ ! -d "$cache_dir" ]; then
          printf '${name}: cache directory not found: %s\n' "$cache_dir" >&2
          exit 1
        fi
      fi

      if [ "$has_data_dir" -eq 1 ]; then
        : > "$control_dir/opencode-has-data-dir"

        if [ "$use_exclusive_sqlite_lock" -eq 1 ]; then
          opencode_lockfile="$data_dir/.opencode-sandbox.lock"
          if [ -e "$opencode_lockfile" ]; then
            printf '${name}: detected leftover lockfile: %s\n' "$opencode_lockfile" >&2
            while true; do
              printf '${name}: adopt lockfile (a), abort (n), continue with :memory: (y)? [a/n/y] ' >&2
              if ! IFS= read -r lock_choice; then
                printf '\n${name}: no response received; aborting\n' >&2
                exit 1
              fi

              case "$lock_choice" in
                a|A)
                  : > "$control_dir/opencode-use-exclusive-sqlite-lock"
                  printf '%s\n' "$opencode_lockfile" > "$control_dir/opencode-lockfile-path"
                  break
                  ;;
                n|N)
                  printf '${name}: aborted by user\n' >&2
                  exit 1
                  ;;
                y|Y)
                  printf '${name}: continuing with OPENCODE_DB=:memory:\n' >&2
                  break
                  ;;
                *)
                  printf '${name}: invalid choice: %s\n' "$lock_choice" >&2
                  ;;
              esac
            done
          else
            : > "$opencode_lockfile"
            : > "$control_dir/opencode-use-exclusive-sqlite-lock"
            printf '%s\n' "$opencode_lockfile" > "$control_dir/opencode-lockfile-path"
          fi
        fi
      fi

      if [ "$has_cache_dir" -eq 1 ]; then
        : > "$control_dir/opencode-has-cache-dir"
      fi

      export AGENT_SANDBOX_CONFIG_DIR="$config_dir"
      export AGENT_SANDBOX_DATA_DIR="$data_dir"
      export AGENT_SANDBOX_CACHE_DIR="$cache_dir"
    '';
    extraCleanup = { ... }: ''
      if [ -r "$control_dir/opencode-lockfile-path" ]; then
        if [ -e "$(< "$control_dir/opencode-lockfile-path")" ]; then
          rm -f "$(< "$control_dir/opencode-lockfile-path")"
        fi
      fi
    '';
  };
}

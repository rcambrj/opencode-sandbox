{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkAgentSandbox {
  inherit pkgs system extraModules showBootLogs enableSshServer sshMaxAttempts;

  name = "opencode-sandbox";

  guestModules = [
    {
      virtualisation.sharedDirectories.opencode-config = {
        source = ''"$AGENT_SANDBOX_CONFIG_DIR"'';
        target = "/mnt/agent-sandbox/config/opencode";
        securityModel = "none";
      };
      virtualisation.sharedDirectories.opencode-data = {
        source = ''"$AGENT_SANDBOX_DATA_DIR"'';
        target = "/mnt/agent-sandbox/data/opencode";
        securityModel = "none";
      };
      virtualisation.sharedDirectories.opencode-cache = {
        source = ''"$AGENT_SANDBOX_CACHE_DIR"'';
        target = "/mnt/agent-sandbox/cache/opencode";
        securityModel = "none";
      };

      systemd.tmpfiles.rules = [
        "d /mnt/agent-sandbox/config 0755 root root -"
        "d /mnt/agent-sandbox/data 0755 root root -"
        "d /mnt/agent-sandbox/cache 0755 root root -"
      ];
    }
  ];

  launcherScript = flake.lib.mkHarnessLauncherScript {
    sessionCommand = { guestSystem, pkgs, ... }: pkgs.writeShellScriptBin "opencode-wrapper" ''
      export OPENCODE_DB=:memory:
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
    };
    extraFinalize = { coreutils, name, emptyDir, ... }: ''
      has_data_dir=0
      has_cache_dir=0

      config_dir="''${config_dir-${emptyDir}}"
      data_dir="''${data_dir-${emptyDir}}"
      cache_dir="''${cache_dir-${emptyDir}}"

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
      fi

      if [ "$has_cache_dir" -eq 1 ]; then
        : > "$control_dir/opencode-has-cache-dir"
      fi

      export AGENT_SANDBOX_CONFIG_DIR="$config_dir"
      export AGENT_SANDBOX_DATA_DIR="$data_dir"
      export AGENT_SANDBOX_CACHE_DIR="$cache_dir"
    '';
  };
}

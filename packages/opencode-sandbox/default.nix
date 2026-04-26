{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkAgentSandbox {
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
      systemd.tmpfiles.rules = [
        "d /mnt/agent-sandbox/config 0755 root root -"
        "d /mnt/agent-sandbox/data 0755 root root -"
        "d /mnt/agent-sandbox/cache 0755 root root -"
      ];

      systemd.services."agent-sandbox-mount-opencode-shares" = {
        unitConfig.DefaultDependencies = false;
        wantedBy = [ "multi-user.target" ];
        after = [ "mnt-agent-sandbox-control.mount" ];
        serviceConfig.Type = "oneshot";
        script = ''
          mount_virtiofs() {
            tag="$1"
            target="$2"

            for _ in 1 2 3 4 5 6 7 8 9 10; do
              if grep -qs " $target " /proc/mounts; then
                return 0
              fi

              if mount -t virtiofs "$tag" "$target" >/dev/null 2>&1; then
                return 0
              fi

              sleep 1
            done

            echo "failed to mount virtiofs tag '$tag' on '$target'" >&2
            return 1
          }

          mkdir -p \
            /mnt/agent-sandbox/config/opencode \
            /mnt/agent-sandbox/data/opencode \
            /mnt/agent-sandbox/cache/opencode

          mount_virtiofs opencode-config /mnt/agent-sandbox/config/opencode

          if [ -e /mnt/agent-sandbox/control/opencode-has-data-dir ]; then
            mount_virtiofs opencode-data /mnt/agent-sandbox/data/opencode
          fi

          if [ -e /mnt/agent-sandbox/control/opencode-has-cache-dir ]; then
            mount_virtiofs opencode-cache /mnt/agent-sandbox/cache/opencode
          fi
        '';
      };
    }
  ];

  launcherScript = flake.lib.mkHarnessLauncherScript {
    sessionCommand = { guestSystem, pkgs, ... }: pkgs.writeShellScriptBin "opencode-wrapper" ''
      ensure_mount() {
        tag="$1"
        target="$2"

        mkdir -p "$target"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          if grep -qs " $target " /proc/mounts; then
            return 0
          fi

          mount -t virtiofs "$tag" "$target" >/dev/null 2>&1 || true
          sleep 1
        done

        echo "required mount not ready: $target ($tag)" >&2
        exit 1
      }

      ensure_mount opencode-config /mnt/agent-sandbox/config/opencode
      export OPENCODE_DB=:memory:
      export XDG_CONFIG_HOME=/mnt/agent-sandbox/config

      if [ -r /mnt/agent-sandbox/control/opencode-has-data-dir ]; then
        ensure_mount opencode-data /mnt/agent-sandbox/data/opencode
        export XDG_DATA_HOME=/mnt/agent-sandbox/data
      fi

      if [ -r /mnt/agent-sandbox/control/opencode-has-cache-dir ]; then
        ensure_mount opencode-cache /mnt/agent-sandbox/cache/opencode
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

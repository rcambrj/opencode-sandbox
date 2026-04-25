{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkAgentSandbox {
  inherit pkgs system extraModules showBootLogs enableSshServer sshMaxAttempts;

  name = "claude-sandbox";

  guestModules = [
    {
      virtualisation.sharedDirectories.claude-config = {
        source = ''"$AGENT_SANDBOX_CONFIG_DIR"'';
        target = "/mnt/agent-sandbox/config/claude";
        securityModel = "none";
      };

      systemd.tmpfiles.rules = [
        "d /mnt/agent-sandbox/config 0755 root root -"
      ];
    }
  ];

  launcherScript = flake.lib.mkHarnessLauncherScript {
    sessionCommand = { guestSystem, ... }: pkgs.writeShellScriptBin "claude-wrapper" ''
      export CLAUDE_CONFIG_DIR=/mnt/agent-sandbox/config/claude

      exec ${pkgs.lib.getExe inputs.numtide-llm-agents.packages.${guestSystem}.claude-code} "$@"
    '';
    extraFlags = {
      config-dir = "config_dir";
    };
    extraFinalize = { coreutils, name, emptyDir, ... }: ''
      if [ -z "''${config_dir:-}" ] || [ "''${config_dir}" = "${emptyDir}" ]; then
        printf '${name}: --config-dir is required and must be a writable host directory\n' >&2
        exit 1
      fi

      config_dir="$(${coreutils}/bin/realpath "$config_dir")"

      if [ ! -d "$config_dir" ]; then
        printf '${name}: config directory not found: %s\n' "$config_dir" >&2
        exit 1
      fi

      if [ ! -w "$config_dir" ]; then
        printf '${name}: config directory is not writable: %s\n' "$config_dir" >&2
        exit 1
      fi

      export AGENT_SANDBOX_CONFIG_DIR="$config_dir"
    '';
  };
}

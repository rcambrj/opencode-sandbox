{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkAgentSandbox {
  inherit pkgs system extraModules showBootLogs enableSshServer sshMaxAttempts;

  name = "mock-sandbox";

  guestModules = [ ];

  launcherScript = flake.lib.mkHarnessLauncherScript {
    sessionCommand = { guestSystem, pkgs, ... }: pkgs.writeShellScriptBin "mock-wrapper" ''
      echo "TEST_AGENT_ARGS_START"
      for arg in "$@"; do
        echo "ARG: $arg"
      done
      echo "TEST_AGENT_ARGS_END"
      echo "CWD=$(pwd)"
      echo "HOME=$HOME"
      if [ -n "''${TEST_AGENT_ENV_VAR:-}" ]; then
        echo "TEST_AGENT_ENV_VAR=$TEST_AGENT_ENV_VAR"
      fi
    '';
  };
}

{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, enableSshServer ? true, sshMaxAttempts ? 15, ... }:

flake.lib.mkSandboxPackage {
  inherit pkgs system extraModules showBootLogs enableSshServer sshMaxAttempts;

  name = "mock-sandbox";

  guestModules = [ ];

  launcherScript = flake.lib.mkLauncherScript {
    sessionCommand = { guestSystem, pkgs, ... }: pkgs.writeShellScriptBin "mock-wrapper" ''
      if [ "''${1:-}" = "fail-stderr" ]; then
        printf 'TEST_AGENT_STDERR_START\n' >&2
        sleep 1
        printf 'TEST_AGENT_STDERR_END\n' >&2
        exit 42
      fi

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

{ lib, opencodeSandboxShowMarkers ? false, perSystem, pkgs, ... }:

let
  opencode = pkgs.writeShellScriptBin "opencode" ''
    OPENCODE_ENABLE_EXA=1 exec ${lib.getExe perSystem.opencode.opencode} "$@"
  '';

  session = pkgs.writeShellScriptBin "opencode-sandbox-session" ''
    set -euo pipefail

    export HOME=/root
    export OPENCODE_DB=:memory:
    export XDG_CONFIG_HOME=/run/opencode-sandbox/config

    if [ -r /run/opencode-sandbox-host/opencode-has-data-dir ]; then
      export XDG_DATA_HOME=/run/opencode-sandbox/data
    fi

    if [ -r /run/opencode-sandbox-host/opencode-has-cache-dir ]; then
      export XDG_CACHE_HOME=/run/opencode-sandbox/cache
    fi

    cd /workspace

    if [ -r /run/opencode-sandbox-host/opencode-env ]; then
      set -a
      source /run/opencode-sandbox-host/opencode-env
      set +a
    fi

    declare -a args=()
    if [ -r /run/opencode-sandbox-host/opencode-args ]; then
      mapfile -t args < /run/opencode-sandbox-host/opencode-args
    fi

    ${lib.optionalString opencodeSandboxShowMarkers ''
      printf '\n=== Starting opencode in /workspace ===\n'
      printf '=== opencode args: %s ===\n\n' "''${args[*]:-(interactive)}"
    ''}

    set +e
    ${lib.getExe opencode} "''${args[@]}"
    rc=$?
    set -e

    ${lib.optionalString opencodeSandboxShowMarkers ''
      printf '\n=== opencode exit code: %s ===\n' "$rc"
    ''}
    ${pkgs.systemd}/bin/poweroff || true
    exit "$rc"
  '';
in
{
  environment.systemPackages = [ opencode session ];

  systemd.services.opencode-sandbox-session = {
    description = "Launch opencode inside the sandbox VM";
    after = [ "local-fs.target" "systemd-user-sessions.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = false;
      ExecStart = lib.getExe session;
      Restart = "no";
    };
  };
}

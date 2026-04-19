{ lib, opencodeSandboxShowMarkers ? false, perSystem, pkgs, ... }:

let
  opencode = perSystem.opencode.opencode;

  session = pkgs.writeShellScriptBin "opencode-sandbox-session" ''
    set -euo pipefail

    export HOME=/root
    export OPENCODE_DB=:memory:
    export XDG_CONFIG_HOME=/mnt/opencode-sandbox/config

    if [ -r /mnt/opencode-sandbox-host/opencode-has-data-dir ]; then
      export XDG_DATA_HOME=/mnt/opencode-sandbox/data
    fi

    if [ -r /mnt/opencode-sandbox-host/opencode-has-cache-dir ]; then
      export XDG_CACHE_HOME=/mnt/opencode-sandbox/cache
    fi

    cd /workspace

    if [ -r /mnt/opencode-sandbox-host/opencode-env ]; then
      set -a
      source /mnt/opencode-sandbox-host/opencode-env
      set +a
    fi

    declare -a args=()
    if [ -r /mnt/opencode-sandbox-host/opencode-args ]; then
      mapfile -t args < /mnt/opencode-sandbox-host/opencode-args
    fi

    command=( ${lib.getExe opencode} "''${args[@]}" )
    printf -v command_line '%q ' "''${command[@]}"
    command_line="''${command_line% }"

    printf 'opencode-sandbox: cwd=%s\n' "$PWD"
    printf 'opencode-sandbox: command=%s\n' "$command_line"

    {
      printf 'cwd=%s\n' "$PWD"
      printf 'command=%s\n' "$command_line"
      printf 'OPENCODE_DB=%s\n' "$OPENCODE_DB"
      printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"
      if [ -n "''${XDG_DATA_HOME:-}" ]; then
        printf 'XDG_DATA_HOME=%s\n' "$XDG_DATA_HOME"
      fi
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
      fi
    } | ${pkgs.systemd}/bin/systemd-cat -t opencode-sandbox-session

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

{
  lib,
  opencodeSandboxArgsFile ? "/run/opencode-sandbox-host/opencode-args",
  opencodeSandboxEnv ? { },
  opencodeSandboxExtraArgs ? [ ],
  opencodeSandboxShowMarkers ? false,
  perSystem,
  pkgs,
  ...
}:

let
  opencode = pkgs.writeShellScriptBin "opencode" ''
    OPENCODE_ENABLE_EXA=1 exec ${lib.getExe perSystem.opencode.opencode} "$@"
  '';

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: ''
      export ${name}=${lib.escapeShellArg value}
    '') opencodeSandboxEnv
  );

  session = pkgs.writeShellScriptBin "opencode-sandbox-session" ''
    set -euo pipefail

    export HOME=/root
    ${envExports}
    cd /workspace

    declare -a args=()
    if [ -r ${lib.escapeShellArg opencodeSandboxArgsFile} ]; then
      mapfile -t args < ${lib.escapeShellArg opencodeSandboxArgsFile}
    fi
    ${lib.optionalString (opencodeSandboxExtraArgs != [ ]) ''
      args+=(${lib.escapeShellArgs opencodeSandboxExtraArgs})
    ''}

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

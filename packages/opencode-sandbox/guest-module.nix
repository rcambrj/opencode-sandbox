{ inputs, lib, perSystem, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
  consolePath = "/dev/${consoleDevice}";

  opencode = pkgs.writeShellScriptBin "opencode" ''
    OPENCODE_ENABLE_EXA=1 exec ${lib.getExe perSystem.opencode.opencode} "$@"
  '';

  session = pkgs.writeShellScriptBin "opencode-sandbox-session" ''
    set -e

    export HOME=/root
    cd /workspace

    printf '\n=== Starting opencode in /workspace ===\n\n'
    ${lib.getExe opencode}
    rc=$?

    ${pkgs.systemd}/bin/poweroff || true
    exit "$rc"
  '';
in
{
  imports = [
    (inputs.nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
  ];

  boot.loader.grub.enable = false;
  boot.kernelParams = [
    "console=${consoleDevice}"
  ];

  networking.hostName = "opencode-sandbox";

  environment.systemPackages = [ opencode session ];

  systemd.services."serial-getty@${consoleDevice}".enable = lib.mkForce false;
  systemd.services.opencode-sandbox-session = {
    description = "Launch opencode inside the sandbox VM";
    after = [ "local-fs.target" "systemd-user-sessions.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = consolePath;
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = false;
      ExecStart = lib.getExe session;
      Restart = "no";
    };
  };

  system.stateVersion = "25.11";
}

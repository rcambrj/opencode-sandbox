{ lib, opencodeSandboxShowBootLogs ? false, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
  consolePath = "/dev/${consoleDevice}";
in
{
  imports = [ ./session-module.nix ];

  boot.loader.grub.enable = false;
  boot.kernelParams = [
    "console=${consoleDevice}"
  ] ++ lib.optionals (!opencodeSandboxShowBootLogs) [
    "quiet"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  networking.hostName = "opencode-sandbox";

  systemd.services."serial-getty@${consoleDevice}".enable = lib.mkForce false;
  systemd.services.opencode-sandbox-session.serviceConfig.TTYPath = consolePath;

  system.stateVersion = "25.11";
}

{ lib, opencodeSandboxShowBootLogs ? false, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
  consolePath = "/dev/${consoleDevice}";
in
{
  imports = [ ./guest-opencode.nix ];

  virtualisation.graphics = false;
  virtualisation.memorySize = 4096;
  virtualisation.cores = 4;
  virtualisation.sharedDirectories.workspace = {
    source = ''"$OPENCODE_SANDBOX_WORKSPACE_DIR"'';
    target = "/workspace";
    securityModel = "mapped-xattr";
  };
  virtualisation.sharedDirectories.control = {
    source = ''"$OPENCODE_SANDBOX_CONTROL_DIR"'';
    target = "/mnt/opencode-sandbox/control";
    securityModel = "mapped-xattr";
  };
  virtualisation.sharedDirectories.opencode-config = {
    source = ''"$OPENCODE_SANDBOX_CONFIG_DIR"'';
    target = "/mnt/opencode-sandbox/config/opencode";
    securityModel = "mapped-xattr";
  };
  virtualisation.sharedDirectories.opencode-data = {
    source = ''"$OPENCODE_SANDBOX_DATA_DIR"'';
    target = "/mnt/opencode-sandbox/data/opencode";
    securityModel = "mapped-xattr";
  };
  virtualisation.sharedDirectories.opencode-cache = {
    source = ''"$OPENCODE_SANDBOX_CACHE_DIR"'';
    target = "/mnt/opencode-sandbox/cache/opencode";
    securityModel = "mapped-xattr";
  };
  systemd.tmpfiles.rules = [
    "d /mnt/opencode-sandbox 0755 root root -"
    "d /mnt/opencode-sandbox/control 0755 root root -"
    "d /mnt/opencode-sandbox/config 0755 root root -"
    "d /mnt/opencode-sandbox/data 0755 root root -"
    "d /mnt/opencode-sandbox/cache 0755 root root -"
  ];
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

{ inputs, lib, perSystem, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
  consolePath = "/dev/${consoleDevice}";
in
{
  imports = [
    (inputs.nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
    ./session-module.nix
  ];

  boot.loader.grub.enable = false;
  boot.kernelParams = [
    "console=${consoleDevice}"
  ];

  networking.hostName = "opencode-sandbox";

  systemd.services."serial-getty@${consoleDevice}".enable = lib.mkForce false;
  systemd.services.opencode-sandbox-session.serviceConfig.TTYPath = consolePath;

  system.stateVersion = "25.11";
}

{ lib, agentSandboxEnableSshServer ? true, agentSandboxShowBootLogs ? false, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
in
{
  virtualisation.graphics = false;
  virtualisation.memorySize = 4096;
  virtualisation.cores = 4;
  virtualisation.sharedDirectories.workspace = {
    source = ''"$AGENT_SANDBOX_WORKSPACE_DIR"'';
    target = "/workspace";
    securityModel = "none";
  };
  virtualisation.sharedDirectories.control = {
    source = ''"$AGENT_SANDBOX_CONTROL_DIR"'';
    target = "/mnt/agent-sandbox/control";
    securityModel = "none";
  };
  systemd.tmpfiles.rules = [
    "d /mnt/agent-sandbox 0755 root root -"
    "d /mnt/agent-sandbox/control 0755 root root -"
  ];
  boot.loader.grub.enable = false;
  boot.kernelParams = [
    "console=${consoleDevice}"
  ] ++ lib.optionals (!agentSandboxShowBootLogs) [
    "quiet"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  networking.hostName = "agent-sandbox";

  services.openssh = {
    enable = agentSandboxEnableSshServer;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      StrictModes = false;
    };
    authorizedKeysFiles = [ "/mnt/agent-sandbox/control/authorized_keys" ];
  };

  networking.firewall.allowedTCPPorts = lib.optionals agentSandboxEnableSshServer [ 22 ];

  systemd.services."serial-getty@${consoleDevice}".enable = lib.mkForce false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  programs.git = {
    enable = true;
    config.safe.directory = [ "*" ];
  };

  system.stateVersion = "25.11";
}

{ lib, agentSandboxHostSystem, agentSandboxExtraShares ? [ ], agentSandboxEnableSshServer ? true, agentSandboxShowBootLogs ? false, pkgs, ... }:

let
  consoleDevice = if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0";
  isDarwinHost = lib.hasSuffix "-darwin" agentSandboxHostSystem;
  allMountDirs = [
    "/workspace"
    "/mnt/agent-sandbox/control"
    "/nix/.ro-store"
    "/nix/.rw-store/store"
    "/nix/.rw-store/work"
  ] ++ map (share: share.mountPoint) agentSandboxExtraShares;

  extraFileSystems = lib.listToAttrs (map (share: {
    name = share.mountPoint;
    value = {
      device = share.tag;
      fsType = "virtiofs";
      neededForBoot = true;
    };
  }) agentSandboxExtraShares);

  mountDirsScript = lib.concatStringsSep " \
        " (map lib.escapeShellArg allMountDirs);

  darwinDeviceArgs = [
    "--device \"virtio-net,nat,mac=00:00:00:00:00:01\""
    "--device \"virtio-fs,sharedDir=$AGENT_SANDBOX_WORKSPACE_DIR,mountTag=workspace\""
    "--device \"virtio-fs,sharedDir=$AGENT_SANDBOX_CONTROL_DIR,mountTag=control\""
  ] ++ map (share:
    lib.concatStrings [
      "--device \"virtio-fs,sharedDir=$"
      share.sourceEnvVar
      ",mountTag="
      share.tag
      "\""
    ]
  ) agentSandboxExtraShares;

  linuxDeviceArgs = [
    "-netdev \"user,id=qemu,hostfwd=tcp:127.0.0.1:$AGENT_SANDBOX_SSH_PORT-:22\""
    "-device \"virtio-net-pci,netdev=qemu,mac=02:00:00:01:01:01\""
    "-chardev \"socket,id=workspace,path=$AGENT_SANDBOX_VIRTIOFSD_DIR/workspace.sock\""
    "-device \"vhost-user-fs-pci,chardev=workspace,tag=workspace\""
    "-chardev \"socket,id=control,path=$AGENT_SANDBOX_VIRTIOFSD_DIR/control.sock\""
    "-device \"vhost-user-fs-pci,chardev=control,tag=control\""
    "-chardev \"socket,id=ro-store,path=$AGENT_SANDBOX_VIRTIOFSD_DIR/ro-store.sock\""
    "-device \"vhost-user-fs-pci,chardev=ro-store,tag=ro-store\""
  ] ++ lib.concatMap (share: [
    "-chardev \"socket,id=${share.tag},path=$AGENT_SANDBOX_VIRTIOFSD_DIR/${share.tag}.sock\""
    "-device \"vhost-user-fs-pci,chardev=${share.tag},tag=${share.tag}\""
  ]) agentSandboxExtraShares;
in
{
  microvm = {
    hypervisor = if isDarwinHost then "vfkit" else "qemu";
    storeOnDisk = false;
    virtiofsd.package = if isDarwinHost then pkgs.writeShellScriptBin "virtiofsd" ''
      exit 1
    '' else pkgs.virtiofsd;
    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
        readOnly = true;
        tag = "ro-store";
      }
    ];
    extraArgsScript = ''
      ${lib.optionalString isDarwinHost ''
      printf '%s\n' ${lib.concatStringsSep " " darwinDeviceArgs}
      ''}

      ${lib.optionalString (!isDarwinHost) ''
      printf '%s\n' ${lib.concatStringsSep " " linuxDeviceArgs}
      ''}
    '';
  };

  fileSystems = {
    "/workspace" = {
      device = "workspace";
      fsType = "virtiofs";
      neededForBoot = true;
    };

    "/mnt/agent-sandbox/control" = {
      device = "control";
      fsType = "virtiofs";
      neededForBoot = true;
    };

    "/nix/.ro-store" = {
      device = "ro-store";
      fsType = "virtiofs";
      options = [ "ro" ];
      neededForBoot = true;
    };

    "/nix/.rw-store" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
      neededForBoot = true;
    };

    "/nix/store" = lib.mkForce {
      device = "overlay";
      fsType = "overlay";
      options = [
        "lowerdir=/nix/.ro-store"
        "upperdir=/nix/.rw-store/store"
        "workdir=/nix/.rw-store/work"
      ];
      neededForBoot = true;
    };
  } // extraFileSystems;

  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.networks."10-ether" = {
    matchConfig.Type = "ether";
    networkConfig.DHCP = "yes";
    dhcpV4Config.ClientIdentifier = "mac";
  };

  boot.initrd.systemd.services."agent-sandbox-mount-points" = {
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "initrd-fs.target" ];
    before = [ "initrd-fs.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p \
        ${mountDirsScript}
    '';
  };

  boot.initrd.availableKernelModules = [ "overlay" ];

  systemd.tmpfiles.rules = [
    "d /mnt/agent-sandbox 0755 root root -"
    "d /mnt/agent-sandbox/control 0755 root root -"
  ];

  systemd.services."agent-sandbox-publish-guest-ip" = lib.mkIf isDarwinHost {
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "mnt-agent-sandbox-control.mount" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ip="$(${pkgs.iproute2}/bin/ip -4 -o addr show scope global | ${pkgs.gawk}/bin/awk '{ split($4, a, "/"); print a[1]; exit }')"
      if [ -n "$ip" ]; then
        printf '%s\n' "$ip" > /mnt/agent-sandbox/control/guest-ip
        exit 0
      fi
      exit 1
    '';
  };
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

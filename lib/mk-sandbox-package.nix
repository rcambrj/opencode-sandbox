{ flake, inputs, normalizeExtraModules }:
{ pkgs
, system
, name
, guestModules
, extraShares ? [ ]
, extraModules ? [ ]
, showBootLogs ? false
, enableSshServer ? true
, sshMaxAttempts ? 15
, launcherScript
}:

let
  emptyDir = pkgs.runCommand "${name}-empty-config" { } "mkdir $out";

  guestSystem =
    {
      "aarch64-darwin" = "aarch64-linux";
      "aarch64-linux" = "aarch64-linux";
      "x86_64-darwin" = "x86_64-linux";
      "x86_64-linux" = "x86_64-linux";
    }.${system} or (throw "${name} does not support host system ${system}");

  hostPkgs = pkgs;
  guestPkgs = import inputs.nixpkgs {
    system = guestSystem;
  };

  moduleArgs = {
    inherit flake inputs pkgs system name guestPkgs guestSystem emptyDir;
    inherit extraShares showBootLogs enableSshServer sshMaxAttempts;
  };

  vmSystem = inputs.nixpkgs.lib.nixosSystem {
    system = guestSystem;
    specialArgs = {
      inherit flake inputs;
      agentSandboxHostSystem = system;
      agentSandboxShowBootLogs = showBootLogs;
      agentSandboxEnableSshServer = enableSshServer;
      agentSandboxExtraShares = extraShares;
    };
    modules = [
      inputs.microvm.nixosModules.microvm
      ./guest-vm.nix
      {
        nixpkgs.hostPlatform = guestSystem;
        microvm.vmHostPackages = hostPkgs;
      }
    ] ++ normalizeExtraModules moduleArgs guestModules
      ++ normalizeExtraModules moduleArgs extraModules;
  };

  vmRunner = vmSystem.config.microvm.declaredRunner;
  vmRunnerFixed = pkgs.runCommand "${name}-microvm-run-fixed" { } ''
    mkdir -p "$out"
    cp -R ${vmRunner}/. "$out"/

    ${pkgs.coreutils}/bin/chmod -R u+w "$out"
    ${pkgs.gnused}/bin/sed -i 's|\x27 ''${runtime_args:-}|\x27 bash ''${runtime_args:-}|' "$out/bin/microvm-run"
    ${pkgs.gnused}/bin/sed -i 's|--device virtio-serial,stdio|--device virtio-serial,logFilePath=$AGENT_SANDBOX_SSH_LOG|' "$out/bin/microvm-run"
    ${pkgs.gnused}/bin/sed -i 's|rm -f agent-sandbox.sock|rm -f "$AGENT_SANDBOX_CONTROL_DIR/microvm.sock"|' "$out/bin/microvm-run"
    ${pkgs.gnused}/bin/sed -i 's|SOCKET_ABS=agent-sandbox.sock|SOCKET_ABS="$AGENT_SANDBOX_CONTROL_DIR/microvm.sock"|' "$out/bin/microvm-run"
    ${pkgs.gnused}/bin/sed -i 's|--restful-uri "unix:///$SOCKET_ABS"|--restful-uri "unix:///$SOCKET_ABS" "$@"|' "$out/bin/microvm-run"
  '';
in
pkgs.writeShellApplication {
  inherit name;

  runtimeInputs = [
    pkgs.coreutils
    pkgs.openssh
  ];

  meta.license = pkgs.lib.licenses.mit;

  passthru = { inherit emptyDir vmSystem; };

  text = launcherScript {
    inherit name emptyDir guestSystem guestPkgs pkgs;
    vmRunner = vmRunnerFixed;
    coreutils = pkgs.coreutils;
    openssh = pkgs.openssh;
    inherit showBootLogs;
    inherit sshMaxAttempts;
    inherit extraShares;
  };
}

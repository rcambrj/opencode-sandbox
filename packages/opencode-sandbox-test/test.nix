{ inputs, pkgs, ... }:

let
  hostPkgs = pkgs;
  hostSystem = hostPkgs.stdenv.hostPlatform.system;
  guestSystem =
    {
      aarch64-darwin = "aarch64-linux";
      aarch64-linux = "aarch64-linux";
      x86_64-linux = "x86_64-linux";
    }.${hostSystem} or (throw "opencode-sandbox-test does not support host system ${hostSystem}");

  guestPerSystem = {
    opencode = inputs.opencode.packages.${guestSystem};
  };
in
hostPkgs.testers.runNixOSTest {
  name = "opencode-sandbox";

  nodes.machine = { pkgs, ... }: let
    consoleDevice = if guestSystem == "aarch64-linux" then "ttyAMA0" else "ttyS0";
  in {
    imports = [
      ../opencode-sandbox/session-module.nix
    ];

    _module.args.perSystem = guestPerSystem;
    _module.args.opencodeSandboxArgsFile = "/run/opencode-sandbox-host/opencode-args";
    _module.args.opencodeSandboxEnv = {
      OPENCODE_DISABLE_MODELS_FETCH = "1";
    };
    _module.args.opencodeSandboxExtraArgs = [ "models" ];
    _module.args.opencodeSandboxShowMarkers = true;

    systemd.services."serial-getty@${consoleDevice}".enable = false;
    systemd.services.opencode-sandbox-session.serviceConfig.TTYPath = "/dev/${consoleDevice}";

    boot.kernelParams = [
      "console=${consoleDevice}"
    ];

    networking.hostName = "opencode-sandbox";
    systemd.tmpfiles.rules = [
      "d /workspace 0755 root root -"
    ];

    system.stateVersion = "25.11";
  };

  testScript = ''
    start_all()

    machine.wait_for_console_text(r"=== Starting opencode in /workspace ===")
    machine.wait_for_console_text(r"=== opencode args: models ===")
    machine.wait_for_console_text(r"Database migration complete\.")
    machine.wait_for_console_text(r"=== opencode exit code: 0 ===")
    machine.wait_for_shutdown()
  '';
}

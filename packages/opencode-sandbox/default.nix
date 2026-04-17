{ flake, inputs, pkgs, system, extraModules ? [ ], ... }:

let
  guestSystem =
    {
      aarch64-darwin = "aarch64-linux";
      aarch64-linux = "aarch64-linux";
      x86_64-linux = "x86_64-linux";
    }.${system} or (throw "opencode-sandbox does not support host system ${system}");

  hostPkgs = pkgs;
  guestPerSystem = {
    opencode = inputs.opencode.packages.${guestSystem};
  };

  vmSystem = inputs.nixpkgs.lib.nixosSystem {
    system = guestSystem;
    specialArgs = {
      inherit flake inputs;
      perSystem = guestPerSystem;
    };
    modules = [
      ./guest-module.nix
      {
        nixpkgs.hostPlatform = guestSystem;

        virtualisation.host.pkgs = hostPkgs;
        virtualisation.graphics = false;
        virtualisation.memorySize = 4096;
        virtualisation.cores = 4;
        virtualisation.sharedDirectories.workspace = {
          source = ''"$SHARED_DIR"'';
          target = "/workspace";
          securityModel = "mapped-xattr";
        };
      }
    ] ++ extraModules;
  };

  vmRunner = vmSystem.config.system.build.vm;
in
pkgs.writeShellApplication {
  name = "opencode-sandbox";

  runtimeInputs = [
    pkgs.coreutils
  ];

  text = ''
    set -euo pipefail

    if [ "$#" -gt 1 ]; then
      printf 'usage: %s [shared-directory]\n' "$0" >&2
      exit 2
    fi

    share_path="''${1:-$PWD}"
    share_path="$(${pkgs.coreutils}/bin/realpath "$share_path")"

    if [ ! -d "$share_path" ]; then
      printf 'opencode-sandbox: shared directory not found: %s\n' "$share_path" >&2
      exit 1
    fi

    runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/opencode-sandbox.XXXXXX")"
    trap 'rm -rf "$runtime_dir"' EXIT INT TERM

    set -- ${vmRunner}/bin/run-*-vm
    if [ "$#" -ne 1 ]; then
      printf 'opencode-sandbox: could not resolve VM runner in %s/bin\n' ${pkgs.lib.escapeShellArg (toString vmRunner)} >&2
      exit 1
    fi

    export SHARED_DIR="$share_path"
    export NIX_DISK_IMAGE="$runtime_dir/opencode-sandbox.qcow2"

    exec "$1"
  '';
}

{ flake, inputs, pkgs, system, extraModules ? [ ], ... }:

let
  # Keep this list in sync with upstream top-level command registration in:
  # https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/index.ts
  # The default TUI entrypoint is `$0 [project]` in:
  # https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/cli/cmd/tui/thread.ts
  opencodeCommands = [
    "acp"
    "mcp"
    "attach"
    "run"
    "generate"
    "debug"
    "account"
    "providers"
    "agent"
    "upgrade"
    "uninstall"
    "serve"
    "web"
    "models"
    "stats"
    "export"
    "import"
    "github"
    "pr"
    "session"
    "plugin"
    "db"
  ];

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
      opencodeSandboxArgsFile = "/run/opencode-sandbox-host/opencode-args";
      opencodeSandboxEnv = { };
      opencodeSandboxExtraArgs = [ ];
      opencodeSandboxShowMarkers = false;
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
        virtualisation.sharedDirectories.control = {
          source = ''"$OPENCODE_SANDBOX_CONTROL_DIR"'';
          target = "/run/opencode-sandbox-host";
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

    share_path="$PWD"
    opencode_args=()

    if [ "$#" -gt 0 ]; then
      case "$1" in
        ${builtins.concatStringsSep "|" opencodeCommands})
          opencode_args+=("$@")
          ;;
        *)
          share_path="$1"
          shift
          opencode_args+=("$@")
          ;;
      esac
    fi

    share_path="$(${pkgs.coreutils}/bin/realpath "$share_path")"

    if [ ! -d "$share_path" ]; then
      printf 'opencode-sandbox: shared directory not found: %s\n' "$share_path" >&2
      exit 1
    fi

    runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/opencode-sandbox.XXXXXX")"
    trap 'rm -rf "$runtime_dir"' EXIT INT TERM

    : > "$runtime_dir/opencode-args"
    for arg in "''${opencode_args[@]}"; do
      printf '%s\n' "$arg" >> "$runtime_dir/opencode-args"
    done

    set -- ${vmRunner}/bin/run-*-vm
    if [ "$#" -ne 1 ]; then
      printf 'opencode-sandbox: could not resolve VM runner in %s/bin\n' ${pkgs.lib.escapeShellArg (toString vmRunner)} >&2
      exit 1
    fi

    export SHARED_DIR="$share_path"
    export OPENCODE_SANDBOX_CONTROL_DIR="$runtime_dir"
    export NIX_DISK_IMAGE="$runtime_dir/opencode-sandbox.qcow2"

    exec "$1"
  '';
}

{ flake, inputs, pkgs, system, extraModules ? [ ], configDir ? null, ... }:

let
  emptyConfigDir = pkgs.runCommand "opencode-sandbox-empty-config" { } "mkdir $out";

  resolvedConfigDir = if configDir != null then configDir else emptyConfigDir;

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
      "aarch64-darwin" = "aarch64-linux";
      "aarch64-linux" = "aarch64-linux";
      "x86_64-darwin" = "x86_64-linux";
      "x86_64-linux" = "x86_64-linux";
    }.${system} or (throw "opencode-sandbox does not support host system ${system}");

  hostPkgs = pkgs;
  guestPerSystem = {
    opencode = inputs.opencode.packages.${guestSystem};
  };

  vmSystem = inputs.nixpkgs.lib.nixosSystem {
    system = guestSystem;
    specialArgs = {
      inherit flake inputs;
      opencodeSandboxShowMarkers = false;
      perSystem = guestPerSystem;
    };
    modules = [
      (inputs.nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
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
        virtualisation.sharedDirectories.opencode-config = {
          source = ''"$CONFIG_DIR"'';
          target = "/run/opencode-sandbox-ro/config";
          securityModel = "none";
        };

        fileSystems."/run/opencode-sandbox-rw" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=0755" ];
          neededForBoot = true;
        };

        fileSystems."/root/.config/opencode" = {
          overlay = {
            lowerdir = [ "/run/opencode-sandbox-ro/config" ];
            upperdir = "/run/opencode-sandbox-rw/upper";
            workdir = "/run/opencode-sandbox-rw/work";
            useStage1BaseDirectories = false;
          };
        };

        systemd.tmpfiles.rules = [
          "d /root/.config 0755 root root -"
        ];
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

  meta.license = pkgs.lib.licenses.mit;

  passthru = { inherit emptyConfigDir; };

  text = ''
    set -euo pipefail

    share_path="$PWD"
    opencode_args=()
    env_files=()
    config_dir="${resolvedConfigDir}"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file)
          shift
          if [ "$#" -eq 0 ]; then
            printf 'opencode-sandbox: --env-file requires a path\n' >&2
            exit 2
          fi
          env_files+=("$1")
          shift
          ;;
        --config-dir)
          shift
          if [ "$#" -eq 0 ]; then
            printf 'opencode-sandbox: --config-dir requires a path\n' >&2
            exit 2
          fi
          config_dir="$1"
          shift
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "$#" -gt 0 ]; then
      case "$1" in
        -*)
          opencode_args+=("$@")
          ;;
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

    config_dir="$(${pkgs.coreutils}/bin/realpath "$config_dir")"

    if [ ! -d "$config_dir" ]; then
      printf 'opencode-sandbox: config directory not found: %s\n' "$config_dir" >&2
      exit 1
    fi

    runtime_dir="$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/opencode-sandbox.XXXXXX")"
    trap 'rm -rf "$runtime_dir"' EXIT INT TERM

    : > "$runtime_dir/opencode-args"
    for arg in "''${opencode_args[@]}"; do
      printf '%s\n' "$arg" >> "$runtime_dir/opencode-args"
    done

    if [ ''${#env_files[@]} -gt 0 ]; then
      : > "$runtime_dir/opencode-env"
      for f in "''${env_files[@]}"; do
        cat "$f" >> "$runtime_dir/opencode-env"
      fi
    fi

    set -- ${vmRunner}/bin/run-*-vm
    if [ "$#" -ne 1 ]; then
      printf 'opencode-sandbox: could not resolve VM runner in %s/bin\n' ${pkgs.lib.escapeShellArg (toString vmRunner)} >&2
      exit 1
    fi

    export SHARED_DIR="$share_path"
    export OPENCODE_SANDBOX_CONTROL_DIR="$runtime_dir"
    export CONFIG_DIR="$config_dir"
    export NIX_DISK_IMAGE="$runtime_dir/opencode-sandbox.qcow2"

    exec "$1"
  '';
}
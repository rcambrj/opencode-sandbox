{ flake, inputs, pkgs, system, extraModules ? [ ], showBootLogs ? false, ... }:

let
  emptyDir = pkgs.runCommand "opencode-sandbox-empty-config" { } "mkdir $out";

  guestSystem =
    {
      "aarch64-darwin" = "aarch64-linux";
      "aarch64-linux" = "aarch64-linux";
      "x86_64-darwin" = "x86_64-linux";
      "x86_64-linux" = "x86_64-linux";
    }.${system} or (throw "opencode-sandbox does not support host system ${system}");

  hostPkgs = pkgs;
  guestPkgs = import inputs.nixpkgs {
    system = guestSystem;
  };

  normalizeExtraModules = modules:
    builtins.map (entry:
      if builtins.isAttrs entry then
        entry
      else if builtins.isFunction entry then
        let
          result = entry guestPkgs;
        in
          if builtins.isAttrs result then
            result
          else
            throw "extraModules function must return an attrset, got: ${builtins.typeOf result}"
      else
        throw "extraModules entries must be attrsets or functions, got: ${builtins.typeOf entry}"
    ) modules;

  vmSystem = inputs.nixpkgs.lib.nixosSystem {
    system = guestSystem;
    specialArgs = {
      inherit flake inputs;
      opencodeSandboxShowBootLogs = showBootLogs;
      opencodeSandboxShowMarkers = false;
      opencode = inputs.numtide-llm-agents.packages.${guestSystem}.opencode;
    };
    modules = [
      (inputs.nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
      ./guest-vm.nix
      {
        nixpkgs.hostPlatform = guestSystem;
        virtualisation.host.pkgs = hostPkgs;
      }
    ] ++ normalizeExtraModules extraModules;
  };

  vmRunner = vmSystem.config.system.build.vm;
in
pkgs.writeShellApplication {
  name = "opencode-sandbox";

  runtimeInputs = [
    pkgs.coreutils
  ];

  meta.license = pkgs.lib.licenses.mit;

  passthru = { inherit emptyDir vmSystem; };

  text = ''
    set -euo pipefail

    share_path="$PWD"
    env_files=()
    config_dir="${emptyDir}"
    data_dir="${emptyDir}"
    cache_dir="${emptyDir}"
    has_data_dir=0
    has_cache_dir=0

    opencode_args=()
    saw_share_path=0

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --)
          shift
          opencode_args+=("$@")
          break
          ;;
        --env-file=*)
          env_files+=("''${1#--env-file=}")
          shift
          ;;
        --config-dir=*)
          config_dir="''${1#--config-dir=}"
          shift
          ;;
        --data-dir=*)
          data_dir="''${1#--data-dir=}"
          has_data_dir=1
          shift
          ;;
        --cache-dir=*)
          cache_dir="''${1#--cache-dir=}"
          has_cache_dir=1
          shift
          ;;
        -*)
          printf 'opencode-sandbox: unknown launcher flag before --: %s\n' "$1" >&2
          exit 2
          ;;
        *)
          if [ "$saw_share_path" -eq 1 ]; then
            printf 'opencode-sandbox: unexpected launcher argument before --: %s\n' "$1" >&2
            exit 2
          fi
          share_path="$1"
          saw_share_path=1
          shift
          ;;
      esac
    done

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

    if [ "$has_data_dir" -eq 1 ]; then
      data_dir="$(${pkgs.coreutils}/bin/realpath "$data_dir")"
      if [ ! -d "$data_dir" ]; then
        printf 'opencode-sandbox: data directory not found: %s\n' "$data_dir" >&2
        exit 1
      fi
    fi

    if [ "$has_cache_dir" -eq 1 ]; then
      cache_dir="$(${pkgs.coreutils}/bin/realpath "$cache_dir")"
      if [ ! -d "$cache_dir" ]; then
        printf 'opencode-sandbox: cache directory not found: %s\n' "$cache_dir" >&2
        exit 1
      fi
    fi

    control_dir="$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/opencode-sandbox.XXXXXX")"
    trap 'rm -rf "$control_dir"' EXIT INT TERM

    : > "$control_dir/opencode-args"
    for arg in "''${opencode_args[@]}"; do
      printf '%s\n' "$arg" >> "$control_dir/opencode-args"
    done

    if [ ''${#env_files[@]} -gt 0 ]; then
      : > "$control_dir/opencode-env"
      for f in "''${env_files[@]}"; do
        cat "$f" >> "$control_dir/opencode-env"
      done
    fi

    if [ "$has_data_dir" -eq 1 ]; then
      : > "$control_dir/opencode-has-data-dir"
    fi

    if [ "$has_cache_dir" -eq 1 ]; then
      : > "$control_dir/opencode-has-cache-dir"
    fi

    set -- ${vmRunner}/bin/run-*-vm
    if [ "$#" -ne 1 ]; then
      printf 'opencode-sandbox: could not resolve VM runner in %s/bin\n' ${pkgs.lib.escapeShellArg (toString vmRunner)} >&2
      exit 1
    fi

    export OPENCODE_SANDBOX_WORKSPACE_DIR="$share_path"
    export OPENCODE_SANDBOX_CONTROL_DIR="$control_dir"
    export OPENCODE_SANDBOX_CONFIG_DIR="$config_dir"
    export OPENCODE_SANDBOX_DATA_DIR="$data_dir"
    export OPENCODE_SANDBOX_CACHE_DIR="$cache_dir"
    export NIX_DISK_IMAGE="$control_dir/opencode-sandbox.qcow2"

    exec "$1"
  '';
}

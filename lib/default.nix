{ flake, inputs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  optionalFlag = name: value:
    lib.optionalString (value != null) "--${name}=${lib.escapeShellArg (toString value)}";

  normalizeExtraModules = guestPkgs: modules:
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
      else if builtins.isPath entry || builtins.isString entry then
        entry
      else
        throw "extraModules entries must be attrsets, functions, or paths, got: ${builtins.typeOf entry}"
    ) modules;

  mkHarnessLauncherScript =
    { sessionCommand
    , sessionPrelude ? (_: "")
    , sessionLogLines ? (_: "")
    , extraInit ? (_: "")
    , extraCaseArms ? (_: "")
    , extraValidation ? (_: "")
    , extraControl ? (_: "")
    , extraExports ? (_: "")
    }:
    args@{ name, emptyDir, vmRunner, coreutils, openssh, nixpkgsLib, guestSystem, guestPkgs, pkgs, ... }:
    let
      sessionPkg = sessionCommand guestSystem;
      sessionExe = lib.getExe sessionPkg;
      sessionPreludeText = sessionPrelude args;
      sessionLogLinesText = sessionLogLines args;
      initText = extraInit args;
      caseArmsText = extraCaseArms args;
      validationText = extraValidation args;
      controlText = extraControl args;
      exportsText = extraExports args;
      remoteScript = ''
        set -euo pipefail

        export HOME=/root
        export SHELL=${guestPkgs.bashInteractive}/bin/bash

        cd /workspace

        if [ -r /mnt/agent-sandbox/control/agent-env ]; then
          set -a
          source /mnt/agent-sandbox/control/agent-env
          set +a
        fi

        declare -a args=()
        if [ -r /mnt/agent-sandbox/control/agent-args ]; then
          mapfile -t args < /mnt/agent-sandbox/control/agent-args
        fi

        ${sessionPreludeText}

        command=( ${sessionExe} "''${args[@]}" )
        printf -v command_line '%q ' "''${command[@]}"
        command_line="''${command_line% }"

        {
          printf 'cwd=%s\n' "$PWD"
          printf 'command=%s\n' "$command_line"
          ${sessionLogLinesText}
        } | ${guestPkgs.systemd}/bin/systemd-cat -t ${name}

        set +e
        ${guestPkgs.bashInteractive}/bin/bash -c ${lib.escapeShellArg "${sessionExe} \"\$@\""} bash "''${args[@]}"
        rc=$?
        set -e

        (
          sleep 1
          ${guestPkgs.systemd}/bin/poweroff || true
        ) >/dev/null 2>&1 &
        exit "$rc"
      '';
    in
    ''
      set -euo pipefail

      export HOME=/root
      export SHELL=${pkgs.bashInteractive}/bin/bash

      share_path="$PWD"
      env_files=()
      agent_args=()
      saw_share_path=0

      ${initText}

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --)
            shift
            agent_args+=("$@")
            break
            ;;
          --env-file=*)
            env_files+=("''${1#--env-file=}")
            shift
            ;;
          ${caseArmsText}
          -*)
            printf '${name}: unknown launcher flag before --: %s\n' "$1" >&2
            exit 2
            ;;
          *)
            if [ "$saw_share_path" -eq 1 ]; then
              printf '${name}: unexpected launcher argument before --: %s\n' "$1" >&2
              exit 2
            fi
            share_path="$1"
            saw_share_path=1
            shift
            ;;
        esac
      done

      share_path="$(${coreutils}/bin/realpath "$share_path")"

      if [ ! -d "$share_path" ]; then
        printf '${name}: shared directory not found: %s\n' "$share_path" >&2
        exit 1
      fi

      ${validationText}

      control_dir="$(${coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/${name}.XXXXXX")"
      trap 'rm -rf "$control_dir"' EXIT INT TERM

      : > "$control_dir/agent-args"
      for arg in "''${agent_args[@]}"; do
        printf '%s\n' "$arg" >> "$control_dir/agent-args"
      done

      if [ ''${#env_files[@]} -gt 0 ]; then
        : > "$control_dir/agent-env"
        for f in "''${env_files[@]}"; do
          cat "$f" >> "$control_dir/agent-env"
        done
      fi

      ${controlText}

      ssh_port=$(( ($$ + RANDOM) % 40000 + 1024 ))

      ssh_client_key="$control_dir/ssh_client_key"
      ssh_known_hosts="$control_dir/ssh_known_hosts"
      ssh_log="$control_dir/serial.log"

      ${openssh}/bin/ssh-keygen -t ed25519 -f "$ssh_client_key" -N "" -q
      chmod 600 "$ssh_client_key"
      ${openssh}/bin/ssh-keygen -y -f "$ssh_client_key" > "$control_dir/authorized_keys"
      chmod 644 "$control_dir/authorized_keys"

      : > "$ssh_known_hosts"

      set -- ${vmRunner}/bin/run-*-vm
      if [ "$#" -ne 1 ]; then
        printf '${name}: could not resolve VM runner in %s/bin\n' ${nixpkgsLib.escapeShellArg (toString vmRunner)} >&2
        exit 1
      fi

      export AGENT_SANDBOX_WORKSPACE_DIR="$share_path"
      export AGENT_SANDBOX_CONTROL_DIR="$control_dir"
      export AGENT_SANDBOX_CONFIG_DIR="${emptyDir}"
      ${exportsText}
      export NIX_DISK_IMAGE="$control_dir/agent-sandbox.qcow2"
      export QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:$ssh_port-:22"

      vm_runner="$1"

      "$vm_runner" >> "$ssh_log" 2>&1 &
      vm_pid=$!

      trap 'kill "$vm_pid" 2>/dev/null || true; wait "$vm_pid" 2>/dev/null || true; rm -rf "$control_dir"' EXIT INT TERM

      echo '${name}: starting VM, waiting for SSH...' >&2

      max_attempts=120
      attempt=0
      while [ $attempt -lt $max_attempts ]; do
        if ${openssh}/bin/ssh \
          -F /dev/null \
          -i "$ssh_client_key" \
          -o "UserKnownHostsFile=$ssh_known_hosts" \
          -o "GlobalKnownHostsFile=/dev/null" \
          -o "StrictHostKeyChecking=accept-new" \
          -o "IdentitiesOnly=yes" \
          -o "PreferredAuthentications=publickey" \
          -o "BatchMode=yes" \
          -o "ConnectTimeout=2" \
          -o "LogLevel=error" \
          -p "$ssh_port" \
          root@127.0.0.1 \
          "exit 0" >/dev/null 2>&1; then
          break
        fi
        attempt=$((attempt + 1))

        if ! kill -0 "$vm_pid" 2>/dev/null; then
          echo '${name}: VM exited during SSH readiness check' >&2
          echo >&2
          echo '--- VM boot log ---' >&2
          cat "$ssh_log" >&2
          echo '--- end boot log ---' >&2
          exit 1
        fi

        sleep 1
      done

      if [ $attempt -eq $max_attempts ]; then
        echo '${name}: SSH readiness timeout' >&2
        echo >&2
        echo '--- VM boot log ---' >&2
        cat "$ssh_log" >&2
        echo '--- end boot log ---' >&2
        exit 1
      fi

      set +e
      ${openssh}/bin/ssh \
        -F /dev/null \
        -tt \
        -i "$ssh_client_key" \
        -o "UserKnownHostsFile=$ssh_known_hosts" \
        -o "GlobalKnownHostsFile=/dev/null" \
        -o "StrictHostKeyChecking=accept-new" \
        -o "IdentitiesOnly=yes" \
        -o "PreferredAuthentications=publickey" \
        -o "LogLevel=quiet" \
        -p "$ssh_port" \
        root@127.0.0.1 \
        ${lib.escapeShellArg "${guestPkgs.bashInteractive}/bin/bash -c ${lib.escapeShellArg remoteScript}"}
      ssh_exit=$?
      set -e

      exit "$ssh_exit"
    '';

  mkAgentSandbox =
    { pkgs
    , system
    , name
    , guestModules
    , extraModules ? [ ]
    , showBootLogs ? false
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

      vmSystem = inputs.nixpkgs.lib.nixosSystem {
        system = guestSystem;
        specialArgs = {
          inherit flake inputs;
          agentSandboxShowBootLogs = showBootLogs;
          agentSandboxShowMarkers = false;
        };
        modules = [
          (inputs.nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
          ./guest-vm.nix
          {
            nixpkgs.hostPlatform = guestSystem;
            virtualisation.host.pkgs = hostPkgs;
          }
        ] ++ normalizeExtraModules guestPkgs guestModules
          ++ normalizeExtraModules guestPkgs extraModules;
      };

      vmRunner = vmSystem.config.system.build.vm;
    in
    pkgs.writeShellApplication {
      inherit name;

      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssh
      ];

      excludeShellChecks = [ "SC1003" ];

      meta.license = pkgs.lib.licenses.mit;

      passthru = { inherit emptyDir vmSystem; };

      text = launcherScript {
        inherit name emptyDir vmRunner guestSystem guestPkgs pkgs;
        coreutils = pkgs.coreutils;
        openssh = pkgs.openssh;
        nixpkgsLib = inputs.nixpkgs.lib;
      };
    };

  mkWrappedAgentSandbox =
    { pkgs
    , name
    , package
    , flags
    }:
    pkgs.writeShellScriptBin name ''
      exec ${lib.getExe package} \
        ${lib.concatStringsSep " " (lib.mapAttrsToList
          (flagName: flagValue:
            optionalFlag flagName flagValue
          )
          (lib.filterAttrs (_: v: v != null) flags)
        )} \
        "$@"
    '';

in
{
  inherit optionalFlag mkAgentSandbox mkHarnessLauncherScript mkWrappedAgentSandbox;
}

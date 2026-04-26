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

  renderExtraFlags = extraFlags:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (flagName: flagSpec:
      if builtins.isString flagSpec then
        ''
          --${flagName}=*)
            ${flagSpec}="''${1#--${flagName}=}"
            shift
            ;;
        ''
      else
        throw "extraFlags.${flagName} must be a string"
    ) extraFlags);

  mkHarnessLauncherScript =
    { sessionCommand
    , extraFlags ? { }
    , extraFinalize ? (_: "")
    }:
    args@{ name, emptyDir, vmRunner, coreutils, openssh, guestSystem, guestPkgs, pkgs, sshMaxAttempts, showBootLogs ? false, extraShares ? [ ], ... }:
    let
      sessionCmd = sessionCommand args;
      caseArmsText = renderExtraFlags extraFlags;
      finalizeText = extraFinalize args;
      extraShareStartText = lib.concatStringsSep "\n" (map (share:
        let
          readonlyFlag = if share.readOnly or false then "1" else "0";
          startLine = "start_virtiofsd " + lib.escapeShellArg share.tag + " \"$" + share.sourceEnvVar + "\" " + readonlyFlag;
        in
        if share ? markerFile && share.markerFile != null then ''
      if [ -e ${lib.escapeShellArg share.markerFile} ]; then
        ${startLine}
      fi
        '' else startLine
      ) extraShares);
      bootLogStreamText = lib.optionalString showBootLogs ''
        tail_pid=""
        ${coreutils}/bin/tail -n +1 -f "$ssh_log" >&2 &
        tail_pid=$!
      '';
      bootLogCleanupText = lib.optionalString showBootLogs ''
        if [ -n "$tail_pid" ]; then
          kill "$tail_pid" 2>/dev/null || true
          wait "$tail_pid" 2>/dev/null || true
        fi
      '';
      bootLogFailureText = lib.optionalString (!showBootLogs) ''
        echo >&2
        echo '--- VM boot log ---' >&2
        cat "$ssh_log" >&2
        echo '--- end boot log ---' >&2
      '';
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

        stderr_log=/mnt/agent-sandbox/control/agent-stderr.log
        : > "$stderr_log"

        set +e
        ${guestPkgs.bashInteractive}/bin/bash -c ${lib.escapeShellArg "${lib.getExe sessionCmd} \"\$@\""} bash "''${args[@]}" \
          2> >(${guestPkgs.coreutils}/bin/tee -a "$stderr_log" >&2)
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

      ssh_port=$(( ($$ + RANDOM) % 40000 + 1024 ))

      ssh_client_key="$control_dir/ssh_client_key"
      ssh_known_hosts="$control_dir/ssh_known_hosts"
      ssh_log="$control_dir/serial.log"
      ssh_target_host="127.0.0.1"
      ssh_target_port="$ssh_port"

      ${openssh}/bin/ssh-keygen -t ed25519 -f "$ssh_client_key" -N "" -q
      chmod 600 "$ssh_client_key"
      ${openssh}/bin/ssh-keygen -y -f "$ssh_client_key" > "$control_dir/authorized_keys"
      chmod 644 "$control_dir/authorized_keys"

      : > "$ssh_known_hosts"

      export AGENT_SANDBOX_SSH_PORT="$ssh_port"

      export AGENT_SANDBOX_WORKSPACE_DIR="$share_path"
      export AGENT_SANDBOX_CONTROL_DIR="$control_dir"
      export AGENT_SANDBOX_CONFIG_DIR="${emptyDir}"
      export AGENT_SANDBOX_SSH_LOG="$ssh_log"
      ${finalizeText}

      export AGENT_SANDBOX_VIRTIOFSD_DIR="$control_dir/virtiofsd"

      virtiofsd_dir="$control_dir/virtiofsd"
      mkdir -p "$virtiofsd_dir"

      virtiofsd_pids=()

      ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      start_virtiofsd() {
        tag="$1"
        source_dir="$2"
        readonly_flag="''${3:-0}"
        socket_path="$virtiofsd_dir/$tag.sock"

        if [ ! -d "$source_dir" ]; then
          printf '%s: shared directory not found: %s\n' '${name}' "$source_dir" >&2
          exit 1
        fi

        extra_args=""
        if [ "$readonly_flag" -eq 1 ]; then
          extra_args="--readonly"
        fi

        ${pkgs.virtiofsd}/bin/virtiofsd \
          --socket-path="$socket_path" \
          --shared-dir="$source_dir" \
          --cache=never \
          $extra_args \
          >/dev/null 2>&1 &
        virtiofsd_pids+=("$!")
      }

      start_virtiofsd workspace "$share_path"
      start_virtiofsd control "$control_dir"
      start_virtiofsd ro-store /nix/store 1
      ${extraShareStartText}
      ''}

      vm_runner=${lib.escapeShellArg "${toString vmRunner}/bin/microvm-run"}

      "$vm_runner" >> "$ssh_log" 2>&1 &
      vm_pid=$!

      ${bootLogStreamText}

      ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      guest_ip=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -s "$control_dir/guest-ip" ]; then
          guest_ip="$(${coreutils}/bin/tr -d '[:space:]' < "$control_dir/guest-ip")"
          break
        fi

        if ! kill -0 "$vm_pid" 2>/dev/null; then
          echo '${name}: VM exited before guest IP was written' >&2
          ${bootLogFailureText}
          exit 1
        fi

        sleep 1
      done

      if [ -z "$guest_ip" ]; then
        echo '${name}: timed out waiting for guest IP file' >&2
        ${bootLogFailureText}
        exit 1
      fi

      ssh_target_host="$guest_ip"
      ssh_target_port=22
      ''}

      trap '
        kill "$vm_pid" 2>/dev/null || true
        kill "''${virtiofsd_pids[@]}" 2>/dev/null || true
        ${bootLogCleanupText}
        wait "$vm_pid" 2>/dev/null || true
        wait "''${virtiofsd_pids[@]}" 2>/dev/null || true
        rm -rf "$control_dir"
      ' EXIT INT TERM

      echo '${name}: starting VM, waiting for SSH...' >&2

      max_attempts=${toString sshMaxAttempts}
      ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      max_attempts=5
      ''}
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
          -o "ConnectTimeout=1" \
          -o "LogLevel=error" \
          -p "$ssh_target_port" \
          root@"$ssh_target_host" \
          "exit 0" >/dev/null 2>&1; then
          break
        fi
        attempt=$((attempt + 1))

        if ! kill -0 "$vm_pid" 2>/dev/null; then
          echo '${name}: VM exited during SSH readiness check' >&2
          ${bootLogFailureText}
          exit 1
        fi

        sleep 1
      done

      if [ $attempt -eq $max_attempts ]; then
        echo '${name}: SSH readiness timeout' >&2
        ${bootLogFailureText}
        exit 1
      fi

      ${lib.optionalString showBootLogs ''
      if [ -n "$tail_pid" ]; then
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
        tail_pid=""
      fi
      ''}

      echo '${name}: SSH ready, connecting...' >&2

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
        -p "$ssh_target_port" \
        root@"$ssh_target_host" \
        ${lib.escapeShellArg "${guestPkgs.bashInteractive}/bin/bash -c ${lib.escapeShellArg remoteScript}"}
      ssh_exit=$?
      set -e

      if [ "$ssh_exit" -ne 0 ] && [ -s "$control_dir/agent-stderr.log" ]; then
        echo >&2
        echo '--- sandbox app stderr ---' >&2
        cat "$control_dir/agent-stderr.log" >&2
        echo '--- end sandbox app stderr ---' >&2
      fi

      exit "$ssh_exit"
    '';

  mkAgentSandbox =
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

      vmSystem = inputs.nixpkgs.lib.nixosSystem {
        system = guestSystem;
        specialArgs = {
          inherit flake inputs;
          agentSandboxHostSystem = system;
          agentSandboxShowBootLogs = showBootLogs;
          agentSandboxEnableSshServer = enableSshServer;
          agentSandboxShowMarkers = false;
          agentSandboxExtraShares = extraShares;
        };
        modules = [
          inputs.microvm.nixosModules.microvm
          ./guest-vm.nix
          {
            nixpkgs.hostPlatform = guestSystem;
            microvm.vmHostPackages = hostPkgs;
          }
        ] ++ normalizeExtraModules guestPkgs guestModules
          ++ normalizeExtraModules guestPkgs extraModules;
      };

      vmRunner = vmSystem.config.microvm.declaredRunner;
      vmRunnerFixed = pkgs.runCommand "${name}-microvm-run-fixed" { } ''
        mkdir -p "$out"
        cp -R ${vmRunner}/. "$out"/

        ${pkgs.coreutils}/bin/chmod -R u+w "$out"
        ${pkgs.gnused}/bin/sed -i 's|\x27 ''${runtime_args:-}|\x27 bash ''${runtime_args:-}|' "$out/bin/microvm-run"
        ${pkgs.gnused}/bin/sed -i 's|--device virtio-serial,stdio|--device virtio-serial,logFilePath=$AGENT_SANDBOX_SSH_LOG|' "$out/bin/microvm-run"
        ${pkgs.gnused}/bin/sed -i 's|--restful-uri "unix:///$SOCKET_ABS"|--restful-uri "unix:///$SOCKET_ABS" "$@"|' "$out/bin/microvm-run"
      '';
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
        inherit name emptyDir guestSystem guestPkgs pkgs;
        vmRunner = vmRunnerFixed;
        coreutils = pkgs.coreutils;
        openssh = pkgs.openssh;
        inherit showBootLogs;
        inherit sshMaxAttempts;
        inherit extraShares;
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

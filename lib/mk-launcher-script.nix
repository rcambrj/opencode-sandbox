{ lib, renderExtraFlags }:
{ sessionCommand
, extraFlags ? { }
, extraFinalize ? (_: "")
}:
args@{ name, emptyDir, vmRunner, coreutils, openssh, guestSystem, guestPkgs, pkgs, sshMaxAttempts, showBootLogs ? false, extraShares ? [ ], ... }:
''
  set -euo pipefail

  #####################################
  # Parse parameters
  #####################################

  workspace_path="$PWD"
  workspace_path_seen=0
  env_files=()
  expose_host_ports_seen=0
  expose_host_ports_csv=""
  expose_host_ports=()
  agent_args=()

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
      --expose-host-ports=*)
        expose_host_ports_seen=1
        expose_host_ports_csv="''${1#--expose-host-ports=}"
        shift
        ;;
      ${renderExtraFlags extraFlags}
      -*)
        printf '${name}: unknown launcher flag before --: %s\n' "$1" >&2
        exit 2
        ;;
      *)
        if [ "$workspace_path_seen" -eq 1 ]; then
          printf '${name}: unexpected launcher argument before --: %s\n' "$1" >&2
          exit 2
        fi
        workspace_path="$1"
        workspace_path_seen=1
        shift
        ;;
    esac
  done

  #####################################
  # Workspace, control dir & env files
  #####################################

  workspace_path="$(${coreutils}/bin/realpath "$workspace_path")"
  if [ ! -d "$workspace_path" ]; then
    printf '${name}: workspace directory not found: %s\n' "$workspace_path" >&2
    exit 1
  fi

  control_dir="$(${coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/${name}.XXXXXX")"

  : > "$control_dir/args"
  for arg in "''${agent_args[@]}"; do
    printf '%s\n' "$arg" >> "$control_dir/args"
  done

  if [ ''${#env_files[@]} -gt 0 ]; then
    : > "$control_dir/env"
    for f in "''${env_files[@]}"; do
      cat "$f" >> "$control_dir/env"
    done
  fi

  if [ "$expose_host_ports_seen" -eq 1 ]; then
    if [ -z "$expose_host_ports_csv" ]; then
      expose_host_ports=()
    elif [[ "$expose_host_ports_csv" =~ [[:space:]] ]]; then
      printf '${name}: --expose-host-ports must not contain whitespace\n' >&2
      exit 2
    elif [[ "$expose_host_ports_csv" == ,* ]] || [[ "$expose_host_ports_csv" == *, ]] || [[ "$expose_host_ports_csv" == *",,"* ]]; then
      printf '${name}: --expose-host-ports contains an empty entry\n' >&2
      exit 2
    else
      IFS=',' read -r -a expose_host_ports <<< "$expose_host_ports_csv"
      if [ ''${#expose_host_ports[@]} -eq 0 ]; then
        expose_host_ports=()
      fi

      seen_ports=","
      for port in "''${expose_host_ports[@]}"; do
        if [ -z "$port" ]; then
          printf '${name}: --expose-host-ports contains an empty entry\n' >&2
          exit 2
        fi

        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
          printf '${name}: invalid host port in --expose-host-ports: %s\n' "$port" >&2
          exit 2
        fi

        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
          printf '${name}: host port out of range in --expose-host-ports: %s\n' "$port" >&2
          exit 2
        fi

        if [[ "$seen_ports" == *",$port,"* ]]; then
          printf '${name}: duplicate host port in --expose-host-ports: %s\n' "$port" >&2
          exit 2
        fi
        seen_ports+="$port,"
      done
    fi
  fi

  #####################################
  # SSH
  #####################################

  ssh_client_key="$control_dir/ssh_client_key"
  ssh_known_hosts="$control_dir/ssh_known_hosts"
  ssh_log="$control_dir/serial.log"
  ssh_target_host="127.0.0.1"
  ssh_target_port="$(( ($$ + RANDOM) % 40000 + 1024 ))"
  ssh_forward_args=()

  for port in "''${expose_host_ports[@]}"; do
    ssh_forward_args+=("-R" "$port:127.0.0.1:$port")
  done

  ${openssh}/bin/ssh-keygen -t ed25519 -f "$ssh_client_key" -N "" -q
  chmod 600 "$ssh_client_key"
  ${openssh}/bin/ssh-keygen -y -f "$ssh_client_key" > "$control_dir/authorized_keys"
  chmod 644 "$control_dir/authorized_keys"
  : > "$ssh_known_hosts"

  sandbox_ssh() {
    ${openssh}/bin/ssh \
      -F /dev/null \
      -i "$ssh_client_key" \
      -o "UserKnownHostsFile=$ssh_known_hosts" \
      -o "GlobalKnownHostsFile=/dev/null" \
      -o "StrictHostKeyChecking=accept-new" \
      -o "IdentitiesOnly=yes" \
      -o "PreferredAuthentications=publickey" \
      "''${ssh_forward_args[@]}" \
      "$@"
  }

  #####################################
  # Linux filesystem shares
  #####################################

  virtiofsd_pids=()

  ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    virtiofsd_dir="$control_dir/virtiofsd"
    mkdir -p "$virtiofsd_dir"

    start_virtiofsd() {
      tag="$1"
      source_dir="$2"
      shift 2
      socket_path="$virtiofsd_dir/$tag.sock"

      if [ ! -d "$source_dir" ]; then
        printf '%s: shared directory not found: %s\n' '${name}' "$source_dir" >&2
        exit 1
      fi

      ${pkgs.virtiofsd}/bin/virtiofsd \
        --socket-path="$socket_path" \
        --shared-dir="$source_dir" \
        --cache=never \
        "$@" \
        >/dev/null 2>&1 &
      virtiofsd_pids+=("$!")
    }

    start_virtiofsd workspace "$workspace_path"
    start_virtiofsd control "$control_dir"
    start_virtiofsd ro-store /nix/store --readonly
    ${lib.concatStringsSep "\n" (map (share:
      let
        readonlyArg = lib.optionalString (share.readOnly or false) " --readonly";
        startLine = "start_virtiofsd " + lib.escapeShellArg share.tag + " \"$" + share.sourceEnvVar + "\"" + readonlyArg;
      in if share ? markerFile && share.markerFile != null then ''
        if [ -e ${lib.escapeShellArg share.markerFile} ]; then
          ${startLine}
        fi
      '' else startLine
    ) extraShares)}
  ''}

  #####################################
  # NIC MAC Address
  #####################################

  read -r mac_b0 mac_b1 mac_b2 mac_b3 mac_b4 mac_b5 _extra <<< "$(${coreutils}/bin/od -An -N6 -tu1 /dev/urandom)"
  if [ -n "''${_extra:-}" ] || [ -z "''${mac_b5:-}" ]; then
    printf '${name}: failed to generate random VM MAC bytes\n' >&2
    exit 1
  fi

  # Use 6 random bytes and force the first byte to be a locally administered
  # unicast address (clear multicast bit0, set local bit1).
  mac_byte0=$(( (mac_b0 | 2) & 254 ))
  mac_address="$(printf '%02x:%02x:%02x:%02x:%02x:%02x' \
    "$mac_byte0" \
    "$((mac_b1))" \
    "$((mac_b2))" \
    "$((mac_b3))" \
    "$((mac_b4))" \
    "$((mac_b5))")"

  #####################################
  # VM runner env, start & shutdown trap
  #####################################

  export AGENT_SANDBOX_SSH_PORT="$ssh_target_port"
  export AGENT_SANDBOX_WORKSPACE_DIR="$workspace_path"
  export AGENT_SANDBOX_CONTROL_DIR="$control_dir"
  export AGENT_SANDBOX_SSH_LOG="$ssh_log"
  export AGENT_SANDBOX_VIRTIOFSD_DIR="''${virtiofsd_dir:-}"
  export AGENT_SANDBOX_VM_MAC="$mac_address"
  ${extraFinalize args}
  ${toString vmRunner}/bin/microvm-run >> "$ssh_log" 2>&1 &
  vm_pid=$!

  tail_pid=""
  ${lib.optionalString showBootLogs ''
    ${coreutils}/bin/tail -n +1 -f "$ssh_log" >&2 &
    tail_pid=$!
  ''}

  trap '
    if [ -n "''${tail_pid:-}" ]; then
      kill "$tail_pid" 2>/dev/null || true
      wait "$tail_pid" 2>/dev/null || true
    fi

    kill "$vm_pid" 2>/dev/null || true
    kill "''${virtiofsd_pids[@]}" 2>/dev/null || true
    wait "$vm_pid" 2>/dev/null || true
    wait "''${virtiofsd_pids[@]}" 2>/dev/null || true

    rm -rf "$control_dir"
  ' EXIT INT TERM

  fail_vm_startup() {
    echo "$1" >&2
    ${lib.optionalString (!showBootLogs) ''
      echo >&2
      echo '--- VM boot log ---' >&2
      cat "$ssh_log" >&2
      echo '--- end boot log ---' >&2
    ''}
    exit 1
  }

  #####################################
  # vfkit guest IP
  #####################################

  ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    guest_ip=""
    max_attempts=20
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
      if [ -s "$control_dir/guest-ip" ]; then
        guest_ip="$(${coreutils}/bin/tr -d '[:space:]' < "$control_dir/guest-ip")"
        break
      fi

      if ! kill -0 "$vm_pid" 2>/dev/null; then
        fail_vm_startup '${name}: VM exited before guest IP was written'
      fi

      attempt=$((attempt + 1))
      sleep 1
    done

    if [ -z "$guest_ip" ]; then
      fail_vm_startup '${name}: timed out waiting for guest IP file'
    fi

    ssh_target_host="$guest_ip"
    ssh_target_port=22
  ''}

  #####################################
  # Try SSH
  #####################################

  echo '${name}: starting VM, waiting for SSH...' >&2

  max_attempts=${toString sshMaxAttempts}
  attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if sandbox_ssh \
      -o "ConnectTimeout=1" \
      -o "BatchMode=yes" \
      -o "LogLevel=error" \
      -p "$ssh_target_port" \
      root@"$ssh_target_host" \
      "exit 0" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))

    if ! kill -0 "$vm_pid" 2>/dev/null; then
      fail_vm_startup '${name}: VM exited during SSH readiness check'
    fi

    sleep 1
  done

  if [ $attempt -eq $max_attempts ]; then
    fail_vm_startup '${name}: SSH readiness timeout'
  fi

  #####################################
  # Connect SSH
  #####################################

  ${lib.optionalString showBootLogs ''
    if [ -n "''${tail_pid:-}" ]; then
      kill "$tail_pid" 2>/dev/null || true
      wait "$tail_pid" 2>/dev/null || true
    fi
  ''}

  echo '${name}: SSH ready, connecting...' >&2

  set +e
  sandbox_ssh \
    -tt \
    -o "LogLevel=quiet" \
    -p "$ssh_target_port" \
    root@"$ssh_target_host" \
    "${pkgs.writeShellScript "remote-command.sh" ''
      set -euo pipefail

      #####################################
      # Start process in guest
      #####################################

      export HOME=/root
      export SHELL=${guestPkgs.bashInteractive}/bin/bash

      cd /workspace

      if [ -r /mnt/agent-sandbox/control/env ]; then
        set -a
        source /mnt/agent-sandbox/control/env
        set +a
      fi

      declare -a args=()
      if [ -r /mnt/agent-sandbox/control/args ]; then
        mapfile -t args < /mnt/agent-sandbox/control/args
      fi

      stderr_log=/mnt/agent-sandbox/control/agent-stderr.log
      : > "$stderr_log"

      set +e
      ${guestPkgs.bashInteractive}/bin/bash -c ${lib.escapeShellArg "${lib.getExe (sessionCommand args)} \"\$@\""} bash "''${args[@]}" \
        2> >(${guestPkgs.coreutils}/bin/tee -a "$stderr_log" >&2)
      rc=$?
      set -e

      (
        sleep 1
        ${guestPkgs.systemd}/bin/poweroff || true
      ) >/dev/null 2>&1 &
      exit "$rc"
    ''}"
  ssh_exit=$?
  set -e

  if [ "$ssh_exit" -ne 0 ] && [ -s "$control_dir/agent-stderr.log" ]; then
    echo >&2
    echo '--- sandbox app stderr ---' >&2
    cat "$control_dir/agent-stderr.log" >&2
    echo '--- end sandbox app stderr ---' >&2
  fi

  exit "$ssh_exit"
''

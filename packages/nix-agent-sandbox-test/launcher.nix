{ flake, pkgs, ... }:

let
  hostPkgs = pkgs;
  hostSystem = hostPkgs.stdenv.hostPlatform.system;

  genericLauncher = hostPkgs.lib.getExe flake.packages.${hostSystem}.mock-sandbox;
  failingSshLauncher = hostPkgs.lib.getExe (flake.packages.${hostSystem}.mock-sandbox.override {
    enableSshServer = false;
    sshMaxAttempts = 1;
  });
  bootLogsLauncher = hostPkgs.lib.getExe (flake.packages.${hostSystem}.mock-sandbox.override {
    enableSshServer = false;
    sshMaxAttempts = 1;
    showBootLogs = true;
  });
  extraModulesAttrsetLauncher = hostPkgs.lib.getExe (flake.packages.${hostSystem}.mock-sandbox.override {
    extraModules = [
      ({ guestPkgs, ... }: {
        environment.systemPackages = [ guestPkgs.hello ];
      })
    ];
  });
  opencodeLauncher = hostPkgs.lib.getExe flake.packages.${hostSystem}.opencode-sandbox;
in
hostPkgs.testers.runNixOSTest {
  name = "nix-agent-sandbox-launcher";

  nodes = {};

  testScript = ''
    import os
    import json
    import shutil
    import socket
    import subprocess
    import tempfile
    import threading
    import contextlib

    generic_launcher = ${builtins.toJSON genericLauncher}
    failing_ssh_launcher = ${builtins.toJSON failingSshLauncher}
    boot_logs_launcher = ${builtins.toJSON bootLogsLauncher}
    extra_modules_attrset_launcher = ${builtins.toJSON extraModulesAttrsetLauncher}
    opencode_launcher = ${builtins.toJSON opencodeLauncher}
    claude_launcher = ${builtins.toJSON (hostPkgs.lib.getExe flake.packages.${hostSystem}.claude-sandbox)}

    # --- Generic mock-sandbox tests ---

    def run_cmd(cmd, expect_success=True, input_text=None):
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
            input=input_text,
        )
        if expect_success and result.returncode != 0:
            raise Exception(f"exit {result.returncode}: {result.stdout}")
        if not expect_success and result.returncode == 0:
            raise Exception(f"expected failure, got success: {result.stdout}")
        return result.stdout

    @contextlib.contextmanager
    def host_listener_once(port=0):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(1)
        selected_port = server.getsockname()[1]
        payload = "HOST_OK_PAYLOAD"
        accepted = {"ok": False, "port": selected_port}

        def _accept_once():
            try:
                conn, _ = server.accept()
                accepted["ok"] = True
                response = (
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: text/plain\r\n"
                    f"Content-Length: {len(payload)}\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    f"{payload}"
                )
                conn.sendall(response.encode("utf-8"))
                conn.close()
            except Exception:
                pass

        thread = threading.Thread(target=_accept_once, daemon=True)
        thread.start()
        try:
            yield accepted
        finally:
            server.close()
            thread.join(timeout=2)

    env_dir = tempfile.mkdtemp(prefix="mock-sandbox-test-env-")
    env_file = os.path.join(env_dir, "env")
    with open(env_file, "w") as f:
        f.write("TEST_AGENT_ENV_VAR=hello-from-env\n")

    out = run_cmd([generic_launcher, "--", "hello", "world"])
    assert "TEST_AGENT_ARGS_START" in out, f"expected args start marker, got: {out!r}"
    assert "ARG: hello" in out, f"expected 'ARG: hello' in output, got: {out!r}"
    assert "ARG: world" in out, f"expected 'ARG: world' in output, got: {out!r}"
    assert "TEST_AGENT_ARGS_END" in out, f"expected args end marker, got: {out!r}"
    assert "mock-sandbox: SSH ready, connecting..." in out, f"expected SSH-ready marker, got: {out!r}"

    out = run_cmd([generic_launcher, f"--env-file={env_file}", "--", "hello", "world"])
    assert "TEST_AGENT_ENV_VAR=hello-from-env" in out, f"expected env var in output, got: {out!r}"

    out = run_cmd([generic_launcher, "hello", "extra"], expect_success=False)
    assert "unexpected launcher argument before --" in out, f"expected strict launcher failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--bogus", "--", "hello"], expect_success=False)
    assert "unknown launcher flag before --" in out, f"expected unknown launcher flag failure, got: {out!r}"

    with host_listener_once() as accepted:
        port = accepted["port"]
        out = run_cmd([generic_launcher, f"--expose-host-ports={port}", "--", "probe-host-port", str(port)])
        assert "HOST_OK_PAYLOAD" in out, f"expected HTTP payload from host listener, got: {out!r}"
        assert accepted["ok"], "expected host listener to receive one connection"

    out = run_cmd([generic_launcher, "--expose-host-ports=21435, 21436", "--", "hello"], expect_success=False)
    assert "must not contain whitespace" in out, f"expected whitespace validation failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=", "--", "hello"])
    assert "TEST_AGENT_ARGS_START" in out, f"expected empty expose-host-ports to be a no-op, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=21434,", "--", "hello"], expect_success=False)
    assert "contains an empty entry" in out, f"expected trailing-comma failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=,21434", "--", "hello"], expect_success=False)
    assert "contains an empty entry" in out, f"expected leading-comma failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=abc", "--", "hello"], expect_success=False)
    assert "invalid host port" in out, f"expected non-numeric expose-host-ports failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=0", "--", "hello"], expect_success=False)
    assert "out of range" in out, f"expected low out-of-range expose-host-ports failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=65536", "--", "hello"], expect_success=False)
    assert "out of range" in out, f"expected high out-of-range expose-host-ports failure, got: {out!r}"

    out = run_cmd([generic_launcher, "--expose-host-ports=21434,21434", "--", "hello"], expect_success=False)
    assert "duplicate host port" in out, f"expected duplicate expose-host-ports failure, got: {out!r}"

    proc = subprocess.Popen(
        [generic_launcher, "--", "fail-stderr"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None, "expected captured stdout pipe"
    live_output = []
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        live_output.append(line)
        if "TEST_AGENT_STDERR_START" in line:
            assert proc.poll() is None, "expected failing sandbox command to still be running while stderr is streaming"
            break

    assert any("TEST_AGENT_STDERR_START" in line for line in live_output), f"expected live stderr start marker, got: {live_output!r}"
    proc.wait(timeout=300)
    remaining_output = proc.stdout.read()
    out = "".join(live_output) + remaining_output
    assert "TEST_AGENT_STDERR_END" in out, f"expected live stderr end marker, got: {out!r}"
    assert out.count("TEST_AGENT_STDERR_START") >= 2, f"expected live stderr plus failure reprint, got: {out!r}"
    assert "--- sandbox app stderr ---" in out, f"expected sandbox app stderr failure block, got: {out!r}"
    assert "--- end sandbox app stderr ---" in out, f"expected sandbox app stderr footer, got: {out!r}"

    out = run_cmd([failing_ssh_launcher, "--", "hello"], expect_success=False)
    assert "SSH readiness timeout" in out, f"expected SSH timeout, got: {out!r}"
    assert "--- VM boot log ---" in out, f"expected boot log banner on SSH failure, got: {out!r}"
    assert "--- end boot log ---" in out, f"expected boot log footer on SSH failure, got: {out!r}"

    out = run_cmd([boot_logs_launcher, "--", "hello"], expect_success=False)
    assert "SSH readiness timeout" in out, f"expected SSH timeout, got: {out!r}"
    assert "--- VM boot log ---" not in out, f"expected streamed boot logs to suppress boot log banner, got: {out!r}"

    out = run_cmd([extra_modules_attrset_launcher, "--", "hello", "world"])
    assert "TEST_AGENT_ARGS_START" in out, f"expected args start marker with attrset extraModules, got: {out!r}"
    assert "ARG: hello" in out, f"expected forwarded args with attrset extraModules, got: {out!r}"

    concurrent_results = []

    def _run_generic_concurrent(instance_id):
        result = subprocess.run(
            [generic_launcher, "--", "hello", f"instance-{instance_id}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        )
        concurrent_results.append((instance_id, result.returncode, result.stdout))

    t1 = threading.Thread(target=_run_generic_concurrent, args=(1,))
    t2 = threading.Thread(target=_run_generic_concurrent, args=(2,))
    t1.start()
    t2.start()
    t1.join(timeout=330)
    t2.join(timeout=330)

    assert len(concurrent_results) == 2, f"expected two concurrent launcher results, got: {concurrent_results!r}"
    for instance_id, rc, out in concurrent_results:
        assert rc == 0, f"expected concurrent launcher #{instance_id} to succeed, got rc={rc}, output: {out!r}"
        assert "mock-sandbox: SSH ready, connecting..." in out, f"expected SSH-ready marker for concurrent launcher #{instance_id}, got: {out!r}"
        assert "ARG: hello" in out, f"expected forwarded args for concurrent launcher #{instance_id}, got: {out!r}"
        assert f"ARG: instance-{instance_id}" in out, f"expected per-instance arg for concurrent launcher #{instance_id}, got: {out!r}"

    os.remove(env_file)
    os.rmdir(env_dir)

    # --- OpenCode sandbox tests ---

    env_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-env-")
    env_file = os.path.join(env_dir, "env")
    with open(env_file, "w") as f:
        f.write("OPENCODE_DISABLE_MODELS_FETCH=1\n")

    config_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-config-")

    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", "models", "extra"], expect_success=False)
    assert "unexpected launcher argument before --" in out, f"expected strict launcher failure, got: {out!r}"

    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", "--bogus", "--", "models"], expect_success=False)
    assert "unknown launcher flag before --" in out, f"expected unknown launcher flag failure, got: {out!r}"

    mock_provider_config = {
        "$schema": "https://opencode.ai/config.json",
        "provider": {
            "mock": {
                "models": {
                    "mock-model": {}
                }
            }
        }
    }
    with open(os.path.join(config_dir, "opencode.json"), "w") as f:
        json.dump(mock_provider_config, f)

    data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-")
    cache_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-cache-")

    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={data_dir}", f"--cache-dir={cache_dir}", "--exclusive-sqlite-lock=false", "--", "models"])
    assert "Database migration complete." in out, f"expected 'Database migration complete.' in output, got: {out!r}"
    assert "mock/mock-model" in out, f"expected custom config model in output, got: {out!r}"

    assert os.path.isdir(os.path.join(data_dir, "log")), "expected XDG data log directory to be created"
    assert not os.path.exists(os.path.join(data_dir, "opencode.db")), "expected no opencode.db when --exclusive-sqlite-lock=false"
    assert not os.path.exists(os.path.join(data_dir, ".opencode-sandbox.lock")), "expected no lockfile when --exclusive-sqlite-lock=false"
    assert os.path.isfile(os.path.join(cache_dir, "version")), "expected XDG cache version file to be created"

    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={data_dir}", f"--cache-dir={cache_dir}", "--exclusive-sqlite-lock=banana", "--", "models"], expect_success=False)
    assert "--exclusive-sqlite-lock must be true or false" in out, f"expected exclusive sqlite lock validation failure, got: {out!r}"

    memory_data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-memory-")
    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={memory_data_dir}", f"--cache-dir={cache_dir}", "--exclusive-sqlite-lock=false", "--", "models"])
    assert not os.path.exists(os.path.join(memory_data_dir, "opencode.db")), "expected no opencode.db when --exclusive-sqlite-lock=false"
    assert not os.path.exists(os.path.join(memory_data_dir, ".opencode-sandbox.lock")), "expected no lockfile when --exclusive-sqlite-lock=false"

    stale_y_data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-stale-y-")
    with open(os.path.join(stale_y_data_dir, ".opencode-sandbox.lock"), "w") as f:
        f.write("stale\n")
    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={stale_y_data_dir}", f"--cache-dir={cache_dir}", "--", "models"], input_text="y\n")
    assert "continue with :memory:" in out, f"expected stale-lock prompt in output, got: {out!r}"
    assert not os.path.exists(os.path.join(stale_y_data_dir, "opencode.db")), "expected no opencode.db when choosing :memory: fallback"
    assert os.path.exists(os.path.join(stale_y_data_dir, ".opencode-sandbox.lock")), "expected stale lockfile to remain when choosing :memory: fallback"

    stale_n_data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-stale-n-")
    with open(os.path.join(stale_n_data_dir, ".opencode-sandbox.lock"), "w") as f:
        f.write("stale\n")
    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={stale_n_data_dir}", f"--cache-dir={cache_dir}", "--", "models"], expect_success=False, input_text="n\n")
    assert "aborted by user" in out, f"expected abort message when choosing n, got: {out!r}"

    stale_a_data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-stale-a-")
    with open(os.path.join(stale_a_data_dir, ".opencode-sandbox.lock"), "w") as f:
        f.write("stale\n")
    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={stale_a_data_dir}", f"--cache-dir={cache_dir}", "--", "--help"], expect_success=False, input_text="a\n")
    assert "adopt lockfile" in out, f"expected stale-lock prompt for adopt path, got: {out!r}"
    assert not os.path.exists(os.path.join(stale_a_data_dir, ".opencode-sandbox.lock")), "expected adopted lockfile to be cleaned up after run"

    os.remove(env_file)
    os.rmdir(env_dir)
    shutil.rmtree(data_dir)
    shutil.rmtree(memory_data_dir)
    shutil.rmtree(stale_y_data_dir)
    shutil.rmtree(stale_n_data_dir)
    shutil.rmtree(stale_a_data_dir)
    shutil.rmtree(cache_dir)
    shutil.rmtree(config_dir)

    # --- Claude sandbox tests ---

    config_dir = tempfile.mkdtemp(prefix="claude-sandbox-test-config-")
    with open(os.path.join(config_dir, "settings.json"), "w") as f:
        json.dump({"permissions": {"allow": ["*"]}}, f)

    out = run_cmd([claude_launcher, f"--config-dir={config_dir}", "models", "extra"], expect_success=False)
    assert "unexpected launcher argument before --" in out, f"expected strict launcher failure, got: {out!r}"

    out = run_cmd([claude_launcher, f"--config-dir={config_dir}", "--bogus", "--", "--help"], expect_success=False)
    assert "unknown launcher flag before --" in out, f"expected unknown launcher flag failure, got: {out!r}"

    out = run_cmd([claude_launcher, "--", "--help"], expect_success=False)
    assert "--config-dir is required" in out, f"expected required config dir failure, got: {out!r}"

    out = run_cmd([claude_launcher, f"--config-dir={config_dir}", "--", "--help"])
    assert "Usage" in out or "usage" in out, f"expected claude help output, got: {out!r}"

    shutil.rmtree(config_dir)
  '';
}

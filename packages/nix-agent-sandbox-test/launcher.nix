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
  opencodeLauncher = hostPkgs.lib.getExe flake.packages.${hostSystem}.opencode-sandbox;
in
hostPkgs.testers.runNixOSTest {
  name = "nix-agent-sandbox-launcher";

  nodes = {};

  testScript = ''
    import os
    import json
    import glob
    import shutil
    import subprocess
    import tempfile

    generic_launcher = ${builtins.toJSON genericLauncher}
    failing_ssh_launcher = ${builtins.toJSON failingSshLauncher}
    boot_logs_launcher = ${builtins.toJSON bootLogsLauncher}
    opencode_launcher = ${builtins.toJSON opencodeLauncher}
    claude_launcher = ${builtins.toJSON (hostPkgs.lib.getExe flake.packages.${hostSystem}.claude-sandbox)}

    # --- Generic mock-sandbox tests ---

    def run_cmd(cmd, expect_success=True):
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        )
        if expect_success and result.returncode != 0:
            raise Exception(f"exit {result.returncode}: {result.stdout}")
        if not expect_success and result.returncode == 0:
            raise Exception(f"expected failure, got success: {result.stdout}")
        return result.stdout

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

    out = run_cmd([opencode_launcher, f"--env-file={env_file}", f"--config-dir={config_dir}", f"--data-dir={data_dir}", f"--cache-dir={cache_dir}", "--", "models"])
    assert "Database migration complete." in out, f"expected 'Database migration complete.' in output, got: {out!r}"
    assert "mock/mock-model" in out, f"expected custom config model in output, got: {out!r}"

    assert os.path.isdir(os.path.join(data_dir, "log")), "expected XDG data log directory to be created"
    assert not glob.glob(os.path.join(data_dir, "opencode-*.db")), "expected no persistent DB files matching opencode-*.db when OPENCODE_DB=:memory:"
    assert os.path.isfile(os.path.join(cache_dir, "version")), "expected XDG cache version file to be created"

    os.remove(env_file)
    os.rmdir(env_dir)
    shutil.rmtree(data_dir)
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

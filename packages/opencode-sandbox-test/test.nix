{ flake, pkgs, ... }:

let
  hostPkgs = pkgs;
  hostSystem = hostPkgs.stdenv.hostPlatform.system;
  launcher = hostPkgs.lib.getExe flake.packages.${hostSystem}.opencode-sandbox;
in
hostPkgs.testers.runNixOSTest {
  name = "opencode-sandbox";

  nodes = {};

  testScript = ''
    import os
    import json
    import shutil
    import subprocess
    import tempfile

    launcher = ${builtins.toJSON launcher}

    env_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-env-")
    env_file = os.path.join(env_dir, "env")
    with open(env_file, "w") as f:
        f.write("OPENCODE_DISABLE_MODELS_FETCH=1\n")

    config_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-config-")

    def run(*args, env_file_arg=env_file, config_dir_arg=config_dir, data_dir_arg=None, cache_dir_arg=None):
        cmd = [launcher]
        if env_file_arg is not None:
            cmd += ["--env-file", env_file_arg]
        if config_dir_arg is not None:
            cmd += ["--config-dir", config_dir_arg]
        if data_dir_arg is not None:
            cmd += ["--data-dir", data_dir_arg]
        if cache_dir_arg is not None:
            cmd += ["--cache-dir", cache_dir_arg]
        cmd += list(args)
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            raise Exception(f"exit {result.returncode}: {result.stdout}")
        return result.stdout

    def run_fail(*args, env_file_arg=env_file, config_dir_arg=config_dir, data_dir_arg=None, cache_dir_arg=None):
        cmd = [launcher]
        if env_file_arg is not None:
            cmd += ["--env-file", env_file_arg]
        if config_dir_arg is not None:
            cmd += ["--config-dir", config_dir_arg]
        if data_dir_arg is not None:
            cmd += ["--data-dir", data_dir_arg]
        if cache_dir_arg is not None:
            cmd += ["--cache-dir", cache_dir_arg]
        cmd += list(args)
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=300,
        )
        if result.returncode == 0:
            raise Exception(f"expected failure, got success: {result.stdout}")
        return result.stdout

    out = run("--", "models")
    assert "Database migration complete." in out, f"expected 'Database migration complete.' in output, got: {out!r}"
    assert "opencode/" in out, f"expected 'opencode/' in output, got: {out!r}"

    out = run_fail("models", "extra")
    assert "unexpected launcher argument before --" in out, f"expected strict launcher failure, got: {out!r}"

    out = run_fail("--bogus", "--", "models")
    assert "unknown launcher flag before --" in out, f"expected unknown launcher flag failure, got: {out!r}"

    out = run("--", "--help")
    assert "Options:" in out and "show help" in out

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

    out = run(f"--config-dir={config_dir}", "--", "models")
    assert "Database migration complete." in out, f"expected 'Database migration complete.' in output, got: {out!r}"
    assert "mock/mock-model" in out, f"expected custom config model in output, got: {out!r}"

    tmpdir = tempfile.mkdtemp(prefix="opencode-sandbox-share-")
    try:
        out = run(tmpdir, f"--config-dir={config_dir}", "--", "--help")
        assert "Options:" in out and "show help" in out
    finally:
        os.rmdir(tmpdir)

    data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-data-")
    cache_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-cache-")
    try:
        out = run("--", "models", data_dir_arg=data_dir, cache_dir_arg=cache_dir)
        assert "Database migration complete." in out, f"expected 'Database migration complete.' in output, got: {out!r}"
        assert os.path.isdir(os.path.join(data_dir, "log")), "expected XDG data log directory to be created"
        assert not os.path.exists(os.path.join(data_dir, "opencode.db")), "expected no persistent DB file when OPENCODE_DB=:memory:"
        assert os.path.isfile(os.path.join(cache_dir, "version")), "expected XDG cache version file to be created"

        combined_config_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-combined-config-")
        with open(os.path.join(combined_config_dir, "opencode.json"), "w") as f:
            json.dump(mock_provider_config, f)
        combined_data_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-combined-data-")
        combined_cache_dir = tempfile.mkdtemp(prefix="opencode-sandbox-test-combined-cache-")
        try:
            out = run(
                f"--config-dir={combined_config_dir}",
                "--",
                "models",
                env_file_arg=env_file,
                config_dir_arg=None,
                data_dir_arg=combined_data_dir,
                cache_dir_arg=combined_cache_dir,
            )
            assert "mock/mock-model" in out, f"expected custom config model in combined output, got: {out!r}"
            assert os.path.isdir(os.path.join(combined_data_dir, "log")), "expected combined XDG data log directory"
            assert os.path.isfile(os.path.join(combined_cache_dir, "version")), "expected combined XDG cache version file"
        finally:
            shutil.rmtree(combined_config_dir)
            shutil.rmtree(combined_data_dir)
            shutil.rmtree(combined_cache_dir)
    finally:
        shutil.rmtree(data_dir)
        shutil.rmtree(cache_dir)

    os.remove(env_file)
    os.rmdir(env_dir)
    shutil.rmtree(config_dir)
  '';
}

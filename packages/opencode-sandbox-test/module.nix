{ flake, pkgs, ... }:

let
  hostPkgs = pkgs;
  hostSystem = hostPkgs.stdenv.hostPlatform.system;

  mockPackage = pkgs.writeShellScriptBin "opencode-sandbox" ''
    echo "ARGS_START"
    for arg in "$@"; do
      echo "ARG: $arg"
    done
    echo "ARGS_END"
  '';
in
hostPkgs.testers.runNixOSTest {
  name = "opencode-sandbox-module";

  nodes.machine = { config, ... }: {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockPackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
    };
  };



  nodes.machineWithDirs = {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockPackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
      dataDir = pkgs.writeTextDir "data" "";
      cacheDir = pkgs.writeTextDir "cache" "";
    };
  };

  nodes.machineCustomEnv = {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockPackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
      envFile = pkgs.writeText "opencode-env" "OPENCODE_TEST=1";
    };
  };

  testScript = ''
    def run_opencode_sandbox(machine, *args):
        result = machine.succeed("opencode-sandbox " + " ".join(args))
        return result

    def parse_args(output):
        lines = output.strip().split("\n")
        args = []
        in_args = False
        for line in lines:
            if line == "ARGS_START":
                in_args = True
                continue
            if line == "ARGS_END":
                in_args = False
                continue
            if in_args and line.startswith("ARG: "):
                args.append(line[5:])
        return args

    machine.wait_for_unit("multi-user.target")

    out = run_opencode_sandbox(machine, "--", "test")
    args = parse_args(out)
    assert "--config-dir" in args, f"expected --config-dir arg, got: {args!r}"
    assert "opencode.json" in str(args), f"expected config dir to contain opencode.json, got: {args!r}"

    out = run_opencode_sandbox(machine, "--", "test")
    args = parse_args(out)
    assert "--data-dir" not in args, f"expected no --data-dir when not configured, got: {args!r}"
    assert "--cache-dir" not in args, f"expected no --cache-dir when not configured, got: {args!r}"

    machineWithDirs.wait_for_unit("multi-user.target")

    out = run_opencode_sandbox(machineWithDirs, "--", "test")
    args = parse_args(out)
    assert "--data-dir" in args, f"expected --data-dir when configured, got: {args!r}"
    assert "--cache-dir" in args, f"expected --cache-dir when configured, got: {args!r}"

    machineCustomEnv.wait_for_unit("multi-user.target")

    out = run_opencode_sandbox(machineCustomEnv, "--", "test")
    args = parse_args(out)
    assert "--env-file" in args, f"expected --env-file when configured, got: {args!r}"

    out = run_opencode_sandbox(machine, "--", "models")
    args = parse_args(out)
    assert "models" in args, f"expected 'models' arg after -- to be forwarded, got: {args!r}"

    out = run_opencode_sandbox(machine, "--", "serve", "--hostname", "0.0.0.0")
    args = parse_args(out)
    assert "serve" in args and "--hostname" in args and "0.0.0.0" in args, f"expected multiple args after -- to be forwarded, got: {args!r}"
  '';
}

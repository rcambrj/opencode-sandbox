{ flake, pkgs, ... }:

let
  hostPkgs = pkgs;

  mockOpencodePackage = pkgs.writeShellScriptBin "opencode-sandbox" ''
    echo "ARGS_START"
    for arg in "$@"; do
      echo "ARG: $arg"
    done
    echo "ARGS_END"
  '';

  mockClaudePackage = pkgs.writeShellScriptBin "claude-sandbox" ''
    echo "ARGS_START"
    for arg in "$@"; do
      echo "ARG: $arg"
    done
    echo "ARGS_END"
  '';
in
hostPkgs.testers.runNixOSTest {
  name = "nix-agent-sandbox-module";

  nodes.machine = { config, ... }: {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockOpencodePackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
      exposeHostPorts = [ 11434 8080 ];
    };
  };

  nodes.machineWithDirs = {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockOpencodePackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
      dataDir = pkgs.writeTextDir "data" "";
      cacheDir = pkgs.writeTextDir "cache" "";
      envFile = pkgs.writeText "opencode-env" "OPENCODE_TEST=1";
      exclusiveSqliteLock = true;
    };
  };

  nodes.machineClaude = { config, ... }: {
    imports = [
      flake.nixosModules.claude-sandbox
    ];

    programs.claude-sandbox = {
      enable = true;
      package = mockClaudePackage;
      configDir = pkgs.writeTextDir "settings.json" (builtins.toJSON {
        permissions = { allow = ["*"]; };
      });
      envFile = pkgs.writeText "claude-env" "CLAUDE_TEST=1";
      exposeHostPorts = [ 9000 ];
    };
  };

  nodes.machineWarningsOpencode = { config, ... }: {
    imports = [
      flake.nixosModules.opencode-sandbox
    ];

    programs.opencode-sandbox = {
      enable = true;
      package = mockOpencodePackage;
      configDir = pkgs.writeTextDir "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
      });
      extraModules = [
        ({ ... }: { })
      ];
      showBootLogs = true;
    };

    assertions = [
      {
        assertion = builtins.any (w: w == "programs.opencode-sandbox.extraModules is ignored when programs.opencode-sandbox.package is set.") config.warnings;
        message = "expected warning for ignored programs.opencode-sandbox.extraModules with package override";
      }
      {
        assertion = builtins.any (w: w == "programs.opencode-sandbox.showBootLogs is ignored when programs.opencode-sandbox.package is set.") config.warnings;
        message = "expected warning for ignored programs.opencode-sandbox.showBootLogs with package override";
      }
    ];
  };

  nodes.machineWarningsClaude = { config, ... }: {
    imports = [
      flake.nixosModules.claude-sandbox
    ];

    programs.claude-sandbox = {
      enable = true;
      package = mockClaudePackage;
      configDir = pkgs.writeTextDir "settings.json" (builtins.toJSON {
        permissions = { allow = ["*"]; };
      });
      extraModules = [
        ({ ... }: { })
      ];
      showBootLogs = true;
    };

    assertions = [
      {
        assertion = builtins.any (w: w == "programs.claude-sandbox.extraModules is ignored when programs.claude-sandbox.package is set.") config.warnings;
        message = "expected warning for ignored programs.claude-sandbox.extraModules with package override";
      }
      {
        assertion = builtins.any (w: w == "programs.claude-sandbox.showBootLogs is ignored when programs.claude-sandbox.package is set.") config.warnings;
        message = "expected warning for ignored programs.claude-sandbox.showBootLogs with package override";
      }
    ];
  };

  testScript = ''
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

    # --- OpenCode sandbox module tests ---

    machine.wait_for_unit("multi-user.target")

    out = machine.succeed("opencode-sandbox -- test")
    args = parse_args(out)
    assert any(arg.startswith("--config-dir=") for arg in args), f"expected --config-dir= arg, got: {args!r}"
    assert "opencode.json" in str(args), f"expected config dir to contain opencode.json, got: {args!r}"
    assert "--expose-host-ports=11434,8080" in args, f"expected --expose-host-ports from module config, got: {args!r}"
    assert not any(arg.startswith("--exclusive-sqlite-lock=") for arg in args), f"expected no explicit --exclusive-sqlite-lock= when unset, got: {args!r}"

    machineWithDirs.wait_for_unit("multi-user.target")

    out = machineWithDirs.succeed("opencode-sandbox -- test")
    args = parse_args(out)
    assert any(arg.startswith("--config-dir=") for arg in args), f"expected --config-dir= arg, got: {args!r}"
    assert any(arg.startswith("--data-dir=") for arg in args), f"expected --data-dir= when configured, got: {args!r}"
    assert any(arg.startswith("--cache-dir=") for arg in args), f"expected --cache-dir= when configured, got: {args!r}"
    assert any(arg.startswith("--env-file=") for arg in args), f"expected --env-file= when configured, got: {args!r}"
    assert "--exclusive-sqlite-lock=true" in args or "--exclusive-sqlite-lock=1" in args, f"expected --exclusive-sqlite-lock=true/1 when configured, got: {args!r}"

    out = machine.succeed("opencode-sandbox -- serve --hostname 0.0.0.0")
    args = parse_args(out)
    assert "serve" in args and "--hostname" in args and "0.0.0.0" in args, f"expected multiple args after -- to be forwarded, got: {args!r}"

    # --- Claude sandbox module tests ---

    machineClaude.wait_for_unit("multi-user.target")

    out = machineClaude.succeed("claude-sandbox -- test")
    args = parse_args(out)
    assert any(arg.startswith("--config-dir=") for arg in args), f"expected --config-dir= arg, got: {args!r}"
    assert "settings.json" in str(args), f"expected config dir to contain settings.json, got: {args!r}"
    assert any(arg.startswith("--env-file=") for arg in args), f"expected --env-file= when configured, got: {args!r}"
    assert "--expose-host-ports=9000" in args, f"expected --expose-host-ports from module config, got: {args!r}"

    # --- Warning checks for ignored options with package override ---

    machineWarningsOpencode.wait_for_unit("multi-user.target")
    machineWarningsClaude.wait_for_unit("multi-user.target")
  '';
}

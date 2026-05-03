# nix-agent-sandbox

Run AI coding agents inside ephemeral NixOS VMs, with optional host-backed config, data, and cache directories.

Currently supported agents:
- **opencode** — `opencode-sandbox`
- **claude** — `claude-sandbox`

Requires `nix`. Don't have it? [Install nix](https://github.com/DeterminateSystems/nix-installer#install-determinate-nix) now.

## Quick start

```sh
# Run opencode in a sandbox:
nix run github:rcambrj/nix-agent-sandbox#opencode-sandbox

# Run claude in a sandbox:
nix run github:rcambrj/nix-agent-sandbox#claude-sandbox

# Pass sandbox args after one `--`:
nix run .#opencode-sandbox -- ~/projects/my-project \
  --data-dir=./data \
  --cache-dir=./cache \
  --config-dir=./config \
  --expose-host-ports=11434,8080

# Pass agent arguments after *another* `--`:
nix run .#opencode-sandbox -- -- --help
nix run .#opencode-sandbox -- /projects/my-project -- models

# Inside the VM, the project is mounted at /workspace.
# Don't pass the host path through to the agent:
nix run .#opencode-sandbox -- -- /projects/my-project
```

## Full configuration

Add this repository to your flake inputs:

```nix
{
  inputs.nix-agent-sandbox.url = "github:rcambrj/nix-agent-sandbox";
}
```

### opencode-sandbox

```nix
{
  imports = [
    inputs.nix-agent-sandbox.nixosModules.opencode-sandbox
  ];

  programs.opencode-sandbox = {
    enable = true;

    envFile = pkgs.writeText "opencode-sandbox-env" (lib.generators.toKeyValue { } {
      OPENCODE_ENABLE_EXA = 1;
    });

    configDir = let
      opencode-json = pkgs.writeText "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        autoupdate = false;
        permission = { "*" = "allow"; };
        default_agent = "plan";

        provider = {
          opencode-go.models."qwen3.5-plus" = {};
          openai.models."gpt-5.4" = {};
          zai-coding-plan.model."glm-5.1" = {};
          ollama = {
            options.baseURL = "http://10.0.2.2:11434/v1";
            models."llama3.1" = {};
          };
        };
      });
    in pkgs.runCommand "opencode-sandbox-config" {} ''
      mkdir -p "$out"
      cp ${opencode-json} "$out/opencode.json"
    '';

    dataDir = /persist/opencode/data;
    cacheDir = /persist/opencode/cache;
    exclusiveSqliteLock = true;
    exposeHostPorts = [ 11434 8080 ];
    showBootLogs = false;
    extraModules = [
      {
        networking.firewall.allowedTCPPorts = [ 4096 ];
      }
      ({ guestPkgs, ... }: {
        environment.systemPackages = [ guestPkgs.hello ];
      })
    ];
  };
}
```

Now run:

```
opencode-sandbox -- --help
```

### claude-sandbox

```nix
{
  imports = [
    inputs.nix-agent-sandbox.nixosModules.claude-sandbox
  ];

  programs.claude-sandbox = {
    enable = true;

    envFile = pkgs.writeText "claude-sandbox-env" (lib.generators.toKeyValue { } {
      ANTHROPIC_API_KEY = "your-key";
    });

    configDir = pkgs.runCommand "claude-sandbox-config" {} ''
      mkdir -p "$out"
      cat > "$out/settings.json" << 'EOF'
      {
        "permissions": { "allow": ["*"] }
      }
      EOF
    '';

    showBootLogs = false;
    exposeHostPorts = [ 11434 ];
  };
}
```

Now run:

```
claude-sandbox -- --help
```

## Notes

> [!NOTE] `opencode` stores its sessions in an sqlite database. Unfortunately
> QEMU/vfkit mounts don't handle sqlite database locks so having multiple
> instances of `opencode-sandbox` running would likely result in a corrupted
> sqlite database very quickly. You could configure opencode with an sqlite
> database path of `:memory:`, which means that you lose:
> - Chat sessions (logs)
> - Hide thinking (/thinking enabled/disabled)
>
> `:memory:` effectively forgets each session as soon as it ends. To mitigate
> this, `opencode-sandbox` implements an exclusive lock system where one sandbox
> instance can control the database but simultaneous concurrent instances
> cannot.
>
> This option is enabled by default, as long as `dataDir` is set. It configures
> `opencode` with `OPENCODE_DB=file:$dataDir/opencode.db?vfs=unix-excl`, creates
> `.opencode-sandbox.lock`, and removes that lock on normal shutdown.
>
> If a leftover lockfile is found at startup, the launcher prompts for:
> continue with `:memory:` (`y`), abort (`n`), or adopt lockfile (`a`).
>
> If `dataDir` is not set, this feature cannot engage and opencode continues with `OPENCODE_DB=:memory:`.
>
> The opencode team have said that [they will not support other databases](https://github.com/anomalyco/opencode/issues/7840#issuecomment-3901180429).
>
> `opencode` probably uses the sqlite database for other things.

> [!WARNING]
> `envFile`, `configDir`, `dataDir`, and `cacheDir` are exposed read-write inside the guest. Take care what you put there.

> [!NOTE]
> `--expose-host-ports=<csv>` exposes host localhost TCP ports to the guest on the same port numbers.
> The CSV value must not contain whitespace (use `11434,8080`, not `11434, 8080`).
> For example, `--expose-host-ports=11434` lets the guest connect to `127.0.0.1:11434` and reach host `127.0.0.1:11434`.

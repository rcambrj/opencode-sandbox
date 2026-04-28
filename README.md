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

# Run the test agent (echo agent for verification):
nix run github:rcambrj/nix-agent-sandbox#mock-sandbox

# Pass sandbox args after one `--`:
nix run .#opencode-sandbox -- ~/projects/my-project \
  --data-dir=./data \
  --cache-dir=./cache \
  --config-dir=./config

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
  };
}
```

## Notes

> [!NOTE]
> The `OPENCODE_DB` environment variable is hardcoded to `:memory:` in the opencode guest module so that opencode doesn't create an sqlite database on disk. This is because the sqlite database is stored on the `dataDir` mount via a QEMU/vfkit share. Unfortunately QEMU/vfkit mounts don't handle sqlite database locks (at all) so having multiple instances of opencode-sandbox running would likely result in a corrupted sqlite database very quickly.
>
> The opencode team have said that [they will not support other databases](https://github.com/anomalyco/opencode/issues/7840#issuecomment-3901180429).
>
> TODO: determine which features are missing as a result

> [!WARNING]
> `envFile`, `configDir`, `dataDir`, and `cacheDir` are exposed read-write inside the guest. Take care what you put there.

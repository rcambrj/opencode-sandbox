# opencode-sandbox

Run `opencode` inside an ephemeral VM, with optional host-backed config, data, and cache directories.

Requires `nix`. Don't have it? [Install nix](https://github.com/DeterminateSystems/nix-installer#install-determinate-nix) now.

## Quick start

```sh
# Run it directly from this flake:
nix run github:rcambrj/opencode-sandbox#opencode-sandbox

# Or clone this repository and run it
nix run .#opencode-sandbox

# Pass sandbox args after one `--`:
nix run .#opencode-sandbox -- ~/projects/my-project \
  --data-dir=./data \
  --cache-dir=./cache \
  --config-dir=./config

# Pass `opencode` arguments after *another* `--`:
nix run .#opencode-sandbox -- -- --help
nix run .#opencode-sandbox -- /projects/my-project -- models

# Inside the VM, the project is mounted at /workspace.
# Don't pass the host path through to opencode:
nix run .#opencode-sandbox -- -- /projects/my-project
```

## Full configuration

Add this repository to your flake inputs:

```nix
{
  inputs.opencode-sandbox.url = "github:rcambrj/opencode-sandbox";
}
```

Import the NixOS module into your system configuration and enable it:

```nix
{
  imports = [
    inputs.opencode-sandbox.nixosModules.opencode-sandbox
  ];

  programs.opencode-sandbox = {
    enable = true;

    envFile = pkgs.writeText "opencode-sandbox-env" (lib.generators.toKeyValue { } {
      OPENCODE_ENABLE_EXA = 1;

      # OPENCODE_API_KEY = "your-opencode-go-key";
      # OPENAI_API_KEY = "your-openai-key";
      # ZHIPU_API_KEY = "your-zai-coding-plan-key";
      #
      # This seems limited, put auth.json in dataDir instead
      # Get the contents from ~/.local/share/opencode/auth.json
      #
      # Also, don't put secrets into the nix store
      # Use sops-nix or agenix (with agenix-template) instead
    });

    configDir = let
      opencode-json = pkgs.writeText "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        autoupdate = false;
        permission = {
          # sandboxed as root, go wild
          "*" = "allow";
        };
        default_agent = "plan";

        # provider/model examples
        provider = {
          opencode-go.models."qwen3.5-plus" = {};
          openai.models."gpt-5.4" = {};
          zai-coding-plan.model."glm-5.1" = {};
          ollama = {
            # Ollama is expected to run outside the sandbox VM.
            # Set `baseURL` to an endpoint reachable from inside the guest.
            # When Ollama is exposed on the VM's host, the QEMU default gateway is `10.0.2.2`:
            options.baseURL = "http://10.0.2.2:11434/v1";
            models."llama3.1" = {};
          };
        };

      });
    in pkgs.runCommand "opencode-sandbox-config" {} ''
      mkdir -p "$out"
      cp ${opencode-json} "$out/opencode.json"

      # put other files in $out/, like AGENTS.md & plugin configuration
    '';

    # optional
    dataDir = /persist/opencode/data;
    cacheDir = /persist/opencode/cache;
    showBootLogs = false;
    extraModules = [
      {
        # for `opencode-sandbox -- serve --hostname 0.0.0.0 --port 4096`
        networking.firewall.allowedTCPPorts = [ 4096 ];
      }
    ];
  };
}
```

This installs `opencode-sandbox` into the system profile.

```sh
# Now run it with
opencode-sandbox

# Pass sandbox args before `--`:
opencode-sandbox ~/projects/my-project \
  --data-dir=./data \
  --cache-dir=./cache \
  --config-dir=./config

# Pass `opencode` arguments after `--`:
opencode-sandbox -- --help
opencode-sandbox /projects/my-project -- models

# Inside the VM, the project is mounted at /workspace.
# Don't pass the host path through to opencode:
opencode-sandbox -- /projects/my-project
```

## Notes

> [!NOTE]
> The `OPENCODE_DB` environment variable is hardcoded to `:memory:` so that opencode doesn't create an sqlite database on disk. This is because the sqlite database is stored on the `dataDir` mount via a QEMU 9p share. Unfortunately QEMU's 9p doesn't handle sqlite database locks (at all) so having multiple instances of opencode-sandbox running would likely result in a corrupted sqlite database very quickly.
>
> The opencode team have said that [they will not support other databases](https://github.com/anomalyco/opencode/issues/7840#issuecomment-3901180429).
>
> TODO: determine which features are missing as a result

> [!WARNING]
> `envFile`, `configDir`, `dataDir`, and `cacheDir` are exposed read-write inside the guest. Take care what you put there.

> [!CAUTION]
> Don't run this as root.
>
> The guest VM mounts the host's nix store. QEMU's 9p filesystem sharing supports restricting a share as readonly, but [nixpkgs qemu-vm.nix doesn't set that](https://github.com/NixOS/nixpkgs/blob/4bd9165a9165d7b5e33ae57f3eecbcb28fb231c9/nixos/modules/virtualisation/qemu-vm.nix#L320), and the default is readwrite. This means that if you start this sandbox as a user who has access to the nix store, the root user in the VM could write to the host's store. In practice, don't run this sandbox as root and you'll be OK.
>
> TODO: add `readonly` to nixpkgs `qemu-vm.nix`

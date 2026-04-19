# opencode-sandbox

Run `opencode` inside an ephemeral VM, with optional host-backed config, data, and cache directories.

Requires `nix`. Don't have it? [Install nix](https://github.com/DeterminateSystems/nix-installer#install-determinate-nix) now.

## Getting Started

### Quick

```sh
# Run it directly from this flake:
nix run github:rcambrj/opencode-sandbox#opencode-sandbox

# Or clone this repository and run it
nix run .#opencode-sandbox

# Pass sandbox args after one `--`:
nix run .#opencode-sandbox -- ~/projects/my-project \
  --data-dir ./data \
  --cache-dir ./cache \
  --config-dir ./config

# Pass `opencode` arguments after *another* `--`:
nix run .#opencode-sandbox -- -- --help
nix run .#opencode-sandbox -- /projects/my-project -- models

# Inside the VM, the project is mounted at /workspace.
# Don't pass the host path through to opencode:
nix run .#opencode-sandbox -- -- /projects/my-project
```

### Complete setup

Add this repository to your flake inputs:

```nix
{
  inputs.opencode-sandbox.url = "github:rcambrj/opencode-sandbox";
}
```

Import the NixOS module and enable it:

```nix
{
  imports = [
    inputs.opencode-sandbox.nixosModules.opencode-sandbox
  ];

  programs.opencode-sandbox = {
    enable = true;

    envFile = pkgs.writeText "opencode-sandbox-env" ''
      OPENCODE_ENABLE_EXA=1
    '';

    configDir = let
      opencode-json = pkgs.writeText "opencode.json" (builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        autoupdate = false;
        permission = {
          # sandboxed as root, go wild
          "*" = "allow";
        };
        default_agent = "plan";
      });
    in pkgs.runCommand "opencode-sandbox-config" {} ''
      mkdir -p "$out"
      cp ${opencode-json} "$out/opencode.json"
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
  --data-dir ./data \
  --cache-dir ./cache \
  --config-dir ./config

# Pass `opencode` arguments after `--`:
opencode-sandbox -- --help
opencode-sandbox /projects/my-project -- models

# Inside the VM, the project is mounted at /workspace.
# Don't pass the host path through to opencode:
opencode-sandbox -- /projects/my-project
```

## Notes

- `envFile`, `configDir`, `dataDir`, and `cacheDir` are exposed via XDG paths inside the guest, take care what you put here as the model has full unrestricted access to them.

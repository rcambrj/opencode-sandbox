# opencode-sandbox

Run `opencode` inside an ephemeral VM, with optional host-backed config, data, and cache directories.

Requires `nix`

## Getting Started

### Quick

```sh
# Run it directly from this flake:
nix run github:rcambrj/opencode-sandbox#opencode-sandbox

# Or clone this repository and run it
nix run .#opencode-sandbox

# Pass sandbox args before `--`:
nix run .#opencode-sandbox -- /projects/my-project
nix run .#opencode-sandbox -- \
  --data-dir ./data \
  --cache-dir ./cache \
  --config-dir ./config

# Pass `opencode` arguments after *another* `--`:
nix run .#opencode-sandbox -- -- --help
nix run .#opencode-sandbox -- /projects/my-project -- models

# Inside the VM, the shared project is mounted at /workspace.
# Do not pass the host path through to opencode:
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
        networking.firewall.allowedTCPPorts = [ 4096 ];
      }
    ];
  };
}
```

This installs `opencode-sandbox` into the system profile.
The firewall example is useful when running `opencode serve --hostname 0.0.0.0 --port 4096` inside the guest.

## Notes

- `envFile`, `configDir`, `dataDir`, and `cacheDir` are exposed via XDG paths inside the guest, take care what you put here as the model has full unrestricted access to them.

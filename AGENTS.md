# AGENTS

## Scope
- `numtide/blueprint` layout.
- Core sandbox logic in `lib/` (`mkAgentSandbox`, `mkWrappedAgentSandbox`, `guest-vm.nix`)
- Harness packages in `packages/<harness>-sandbox/` (e.g., `opencode-sandbox`, `claude-sandbox`, `mock-sandbox`)
- NixOS modules in `modules/nixos/<harness>-sandbox.nix`
- Shared wrapper helpers in `lib/default.nix`

## Architecture
- `lib/mkAgentSandbox` — harness-agnostic function that builds a NixOS VM and wraps it in a `writeShellApplication`. Each harness provides its own `guestModules` and `launcherScript`.
- `lib/mkWrappedAgentSandbox` — generic wrapper that takes a `flags` attrset and produces a shell script that forwards flag arguments to the sandbox package.
- `lib/guest-vm.nix` — base guest NixOS module (VM settings, SSH, workspace+control mounts, boot config). Harness-specific mounts and session setup live in each harness's `guestModules`.
- Each harness package (`packages/<harness>-sandbox/`) calls `mkAgentSandbox` with:
  - `name` — executable name (e.g., `"opencode-sandbox"`)
  - `guestModules` — list of NixOS modules for the guest (session setup, agent-specific mounts)
  - `launcherScript` — function returning the host-side launcher script text

## Rules
- Read the relevant files before changing them.
- Prefer the smallest correct change.
- Keep the CLI contract strict:
  - sandbox args before `--`
  - agent args after `--`
- Prefer CLI arguments over package overrides.
- VM must remain ephemeral.
- Assume multiple sandbox instances may run concurrently; avoid designs that increase sqlite lock contention.
- Keep wrapper generation logic shared via `lib/default.nix`; do not duplicate wrapper construction across module/devshell code.
- Preserve the two-stage Blueprint module export so the module captures this flake when imported by another flake.
- Verify README examples against actual Nix types and generated file formats.
- When adding a new harness, create: `packages/<harness>-sandbox/`, `modules/nixos/<harness>-sandbox.nix`, and update tests.

## Verify
- Always run `nix build .#nix-agent-sandbox-test` unless changes are to docs only
- Launcher tests and the NixOS module tests are in separate files
- All tests are run by this one convenient package
- Starting VMs is costly so test as many features as possible in each instantiation
- For specific verification scenarios run:
  - `nix run .#opencode-sandbox -- <launcher args> -- <opencode args>`
  - `nix run .#claude-sandbox -- <launcher args> -- <claude args>`
  - `nix run .#mock-sandbox -- <launcher args> -- <test-agent args>`

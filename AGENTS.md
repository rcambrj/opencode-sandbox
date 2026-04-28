# AGENTS

## Scope
- `numtide/blueprint` layout.
- Core sandbox logic in `lib/` (`mkSandboxPackage`, `mkLauncherScript`, `mkWrappedExec`, `guest-vm.nix`)
- Harness packages in `packages/<harness>-sandbox/` (e.g., `opencode-sandbox`, `claude-sandbox`, `mock-sandbox`)
- NixOS modules in `modules/nixos/<harness>-sandbox.nix`
- Shared wrapper helpers in `lib/default.nix`

## Architecture
- `lib/mkSandboxPackage` — harness-agnostic function that builds a NixOS VM and wraps it in a `writeShellApplication`. Each harness provides its own `guestModules` and `launcherScript`.
- `lib/mkWrappedExec` — generic wrapper that takes a `flags` attrset and produces a shell script that forwards flag arguments to the sandbox package.
- `lib/guest-vm.nix` — base guest NixOS module (VM settings, SSH, workspace+control mounts, boot config). Harness-specific mounts and session setup live in each harness's `guestModules`.
- Each harness package (`packages/<harness>-sandbox/`) calls `mkSandboxPackage` with:
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
- Always conclude by running `nix build .#nix-agent-sandbox-test` (unless changes are to docs only) to verify the whole test suite
- Launcher tests and the NixOS module tests are in separate files
- All tests are run by this one convenient package
- Starting VMs is costly so test as many features as possible in each instantiation
- If the VM, SSH or harness isn't coming up, it's faster to iterate with just that command instead of running the test suite
- For specific verification commands run:
  - `nix run .#mock-sandbox -- <launcher args> -- <test-agent args>` example: `nix run .#mock-sandbox -- -- hello world`
  - `nix run .#claude-sandbox -- <launcher args> -- <claude args>` example: `nix run .#claude-sandbox -- -- --help`
  - `nix run .#opencode-sandbox -- <launcher args> -- <opencode args>` example: `nix run .#opencode-sandbox -- -- --help`

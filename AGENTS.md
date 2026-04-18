# AGENTS

## Scope
- [numtide/blueprint](https://github.com/numtide/blueprint) layout.
- Launcher logic in `packages/opencode-sandbox/`
- Package in `modules/nixos/opencode-sandbox.nix`

## Rules
- Read the relevant files before changing them
- Prefer the smallest correct change
- Keep the CLI contract strict:
	- sandbox args before `--`
	- opencode args after `--`
- Prefer CLI arguments over package overrides
- VM must remain ephemeral
- Consider multiple instances of opencode-sandbox may run at the same time (impacts sqlite lock)

## Verify
- `nix build .#opencode-sandbox-test`

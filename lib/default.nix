{ flake, inputs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  # Build the host-side launcher script used to boot and connect to the VM.
  mkLauncherScript = import ./mk-launcher-script.nix {
    inherit lib renderExtraFlags;
  };

  # Build an executable sandbox package with a guest VM and launcher.
  mkSandboxPackage = import ./mk-sandbox-package.nix {
    inherit flake inputs normalizeExtraModules;
  };

  # Wrap a sandbox package with default launcher flags.
  mkWrappedExec = import ./mk-wrapped-exec.nix {
    inherit lib optionalFlag;
  };

  # Build reusable NixOS module options for sandbox launchers.
  mkSandboxModuleOptions = import ./mk-sandbox-module-options.nix {
    inherit lib;
  };

  # Internal helpers
  normalizeExtraModules = import ./normalize-extra-modules.nix { };
  renderExtraFlags = import ./render-extra-flags.nix {
    inherit lib;
  };
  optionalFlag = import ./optional-flag.nix {
    inherit lib;
  };
in
{
  inherit optionalFlag mkSandboxPackage mkLauncherScript mkWrappedExec mkSandboxModuleOptions;
}

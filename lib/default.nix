{ flake, inputs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  optionalFlag = import ./optional-flag.nix {
    inherit lib;
  };

  normalizeExtraModules = import ./normalize-extra-modules.nix { };

  renderExtraFlags = import ./render-extra-flags.nix {
    inherit lib;
  };

  mkLauncherScript = import ./mk-launcher-script.nix {
    inherit lib renderExtraFlags;
  };

  mkSandboxPackage = import ./mk-sandbox-package.nix {
    inherit flake inputs normalizeExtraModules;
  };

  mkWrappedExec = import ./mk-wrapped-exec.nix {
    inherit lib optionalFlag;
  };
in
{
  inherit optionalFlag mkSandboxPackage mkLauncherScript mkWrappedExec;
}

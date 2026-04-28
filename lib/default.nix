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

  mkHarnessLauncherScript = import ./mk-harness-launcher-script.nix {
    inherit lib renderExtraFlags;
  };

  mkAgentSandbox = import ./mk-agent-sandbox.nix {
    inherit flake inputs normalizeExtraModules;
  };

  mkWrappedAgentSandbox = import ./mk-wrapped-agent-sandbox.nix {
    inherit lib optionalFlag;
  };
in
{
  inherit optionalFlag mkAgentSandbox mkHarnessLauncherScript mkWrappedAgentSandbox;
}

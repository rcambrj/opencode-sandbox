{ flake, inputs, ... }:

let
  inherit (inputs.nixpkgs) lib;

  optionalFlag = name: value:
    lib.optionalString (value != null) "--${name}=${lib.escapeShellArg (toString value)}";
in
{
  inherit optionalFlag;

  mkWrappedOpencodeSandbox =
    { pkgs
    , name ? "opencode-sandbox"
    , package
    , configDir
    , envFile ? null
    , dataDir ? null
    , cacheDir ? null
    }:
    pkgs.writeShellScriptBin name ''
      exec ${lib.getExe package} \
        ${optionalFlag "config-dir" configDir} \
        ${optionalFlag "env-file" envFile} \
        ${optionalFlag "data-dir" dataDir} \
        ${optionalFlag "cache-dir" cacheDir} \
        "$@"
    '';
}

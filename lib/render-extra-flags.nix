{ lib }:
extraFlags:
lib.concatStringsSep "\n" (lib.mapAttrsToList (flagName: flagSpec:
  if builtins.isString flagSpec then
    ''
      --${flagName}=*)
        ${flagSpec}="''${1#--${flagName}=}"
        shift
        ;;
    ''
  else
    throw "extraFlags.${flagName} must be a string"
) extraFlags)

{ lib, optionalFlag }:
{ pkgs
, name
, package
, flags
}:
pkgs.writeShellScriptBin name ''
  exec ${lib.getExe package} \
    ${lib.concatStringsSep " " (lib.mapAttrsToList
      (flagName: flagValue:
        optionalFlag flagName flagValue
      )
      (lib.filterAttrs (_: v: v != null) flags)
    )} \
    "$@"
''

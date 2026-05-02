{ lib }:

{
  enableDescription,
  packageDescription,
}:
{
  enable = lib.mkEnableOption enableDescription;

  extraModules = lib.mkOption {
    type = lib.types.listOf (lib.types.either lib.types.attrs lib.types.unspecified);
    default = [ ];
    description = ''
      Additional guest NixOS modules to include in the sandbox VM.

      Each entry can be:
      - An attrset (a plain NixOS module): `{ ... }`
      - A function that receives sandbox arguments and returns an attrset: `args: { ... }`
        (for example: `({ guestPkgs, ... }: { ... })`)

      Multiple functions are supported and their results are concatenated.
    '';
  };

  showBootLogs = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Show guest kernel and systemd boot logs on the sandbox console.";
  };

  envFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Path to an env file sourced inside the sandbox VM before the sandboxed app starts.";
  };

  exposeHostPorts = lib.mkOption {
    type = lib.types.listOf lib.types.int;
    default = [ ];
    description = ''
      Host TCP ports exposed into the guest on the same port numbers.
      Guest connections to 127.0.0.1:<port> are forwarded to host 127.0.0.1:<port>.
    '';
  };

  package = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = packageDescription;
  };
}

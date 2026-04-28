{ lib }:
name: value:
lib.optionalString (value != null) "--${name}=${lib.escapeShellArg (toString value)}"

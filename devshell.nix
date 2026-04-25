{ flake, pkgs }:
pkgs.mkShell {
  packages = [
    (flake.lib.mkWrappedAgentSandbox {
      inherit pkgs;
      name = "opencode-sandbox-dev";
      package = flake.packages.${pkgs.stdenv.hostPlatform.system}.opencode-sandbox.override {
        extraModules = [];
        showBootLogs = true;
      };
      flags = {
        env-file = pkgs.writeText "opencode-sandbox-env" ''
          OPENCODE_ENABLE_EXA=1
        '';
        config-dir = let
          opencode-json = pkgs.writeText "opencode.json" (builtins.toJSON {
            "$schema" = "https://opencode.ai/config.json";
            autoupdate = false;
            permission = {
              "*" = "allow";
            };
            default_agent = "plan";
          });
        in pkgs.runCommand "opencode-sandbox-config" {} ''
          mkdir -p "$out"
          cp ${opencode-json} "$out/opencode.json"
        '';
        data-dir = null;
        cache-dir = null;
      };
    })

    (flake.lib.mkWrappedAgentSandbox {
      inherit pkgs;
      name = "claude-sandbox-dev";
      package = flake.packages.${pkgs.stdenv.hostPlatform.system}.claude-sandbox.override {
        extraModules = [];
        showBootLogs = true;
      };
      flags = {};
    })
  ];

  env = { };
  shellHook = "";
}

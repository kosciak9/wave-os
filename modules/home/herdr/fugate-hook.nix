{
  lib,
  pkgs,
  config,
  ...
}:

let
  inherit (import ./fugate-status.nix { inherit lib pkgs; }) statusHook;
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
in
{
  # Herdr's installers keep foreign hook entries, so the Stop hook is merged
  # after each reinstall instead of being owned through a Nix-managed file.
  # Codex runs only trusted hooks, so the installer also records trust for
  # this hook and Herdr's Codex hooks.
  home.activation.fugateStatusHook =
    lib.hm.dag.entryAfter
      [
        "herdrIntegrations"
        "claudeSettings"
      ]
      ''
        run ${lib.getExe python} ${./fugate-status-install.py} ${statusHook} ${builtins.storeDir} \
          ${lib.escapeShellArg "${claudeDirectory}/settings.json"} ${lib.escapeShellArg codexDirectory}
      '';
}

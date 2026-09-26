{
  lib,
  writeShellApplication,
  opencode2,
  pass,
  homeDirectory,
  profileDirectory,
}:

writeShellApplication {
  name = "opencode2-server";
  runtimeInputs = [ pass ];
  text = ''
    export HOME=${lib.escapeShellArg homeDirectory}
    export PATH=${lib.escapeShellArg "${profileDirectory}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}:"$PATH"
    export XDG_CONFIG_HOME="$HOME/.config/opencode-v2"
    export XDG_DATA_HOME="$HOME/.local/share/opencode-v2"
    export XDG_CACHE_HOME="$HOME/.cache/opencode-v2"
    export XDG_STATE_HOME="$HOME/.local/state/opencode-v2"
    export OPENCODE_SERVER_USERNAME=opencode
    OPENCODE_SERVER_PASSWORD="$(pass show opencode.localhost/opencode)"
    export OPENCODE_SERVER_PASSWORD

    exec ${lib.getExe opencode2} serve --hostname 127.0.0.1 --port 51200
  '';
}

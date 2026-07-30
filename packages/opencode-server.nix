{
  lib,
  writeShellApplication,
  opencode,
  pass,
  homeDirectory,
  profileDirectory,
}:

writeShellApplication {
  name = "opencode-server";
  runtimeInputs = [ pass ];
  text = ''
    export HOME=${lib.escapeShellArg homeDirectory}
    export PATH=${lib.escapeShellArg "${profileDirectory}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}:"$PATH"
    export OPENCODE_SERVER_USERNAME=opencode
    OPENCODE_SERVER_PASSWORD="$(pass show opencode.localhost/opencode)"
    export OPENCODE_SERVER_PASSWORD

    exec ${lib.getExe opencode} serve --hostname 127.0.0.1 --port 51199
  '';
}

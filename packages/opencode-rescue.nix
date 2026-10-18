{
  lib,
  writeShellApplication,
  runCommand,
  installShellFiles,
  opencode,
}:
# Free OpenCode models with the default configuration, for when the gateway or
# its secrets are down. --standalone avoids the background service, which keeps
# the configuration it was started with.
let
  script = writeShellApplication {
    name = "opencode-rescue";
    text = ''
      config=$(mktemp -d)
      trap 'rm -rf "$config"' EXIT
      OPENCODE_CONFIG_DIR=$config ${lib.getExe opencode} --standalone "$@"
    '';
  };
in
runCommand "opencode-rescue"
  {
    nativeBuildInputs = [ installShellFiles ];
    meta.mainProgram = "opencode-rescue";
  }
  ''
    install -Dm755 ${lib.getExe script} $out/bin/opencode-rescue
    installShellCompletion --zsh --name _opencode-rescue ${./opencode-rescue.zsh}
  ''

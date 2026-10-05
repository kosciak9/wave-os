{
  lib,
  writeShellApplication,
  python3,
  jq,
  rclone,
  sops,
  stdenv,
  systemd,
  upstream,
  sourceFile,
  cacheFile,
  rcloneConfigFile,
}:

writeShellApplication {
  name = "sops-install-secrets";
  runtimeInputs = [
    jq
    rclone
    sops
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ systemd ];
  text = ''
    mode=cached
    if [[ "''${1:-}" == --refresh ]]; then
      mode=refresh
      shift
    fi
    exec ${lib.getExe python3} ${../tools/wave_secrets.py} \
      ${lib.escapeShellArg "${upstream}/bin/sops-install-secrets"} \
      ${lib.escapeShellArg sourceFile} \
      ${lib.escapeShellArg cacheFile} \
      ${lib.escapeShellArg (if rcloneConfigFile == null then "" else rcloneConfigFile)} \
      "$mode" "$@"
  '';
}

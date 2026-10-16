{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  installShellFiles,
  writeText,
  gcc-unwrapped,
  libx11,
  libxi,
  libxkbcommon,
  gtk3,
  gtk4,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cua-driver";
  version = "0.36.0";

  src = fetchurl {
    url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v${finalAttrs.version}/cua-driver-rs-${finalAttrs.version}-linux-x86_64-binary.tar.gz";
    hash = "sha256-BdriFgyGvfSFXCedMImCE9ehUO2xmSt0cK/dafDfQGQ=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    installShellFiles
  ];
  buildInputs = [
    gcc-unwrapped.lib
    libx11
    libxi
    libxkbcommon
  ];
  runtimeDependencies = [
    gtk3
    gtk4
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 cua-driver "$out/libexec/cua-driver"
    install -Dm755 cua-cursor-theme "$out/libexec/cua-cursor-theme"
    makeWrapper "$out/libexec/cua-driver" "$out/bin/cua-driver" \
      --set CUA_DRIVER_RS_TELEMETRY_ENABLED false \
      --set CUA_DRIVER_RS_UPDATE_CHECK false
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --zsh --name _cua-driver ${writeText "cua-driver.zsh" ''
      #compdef cua-driver

      local state
      local -a commands
      commands=(
        'mcp:Run the stdio MCP server'
        'serve:Run the local daemon'
        'status:Show daemon status'
        'stop:Stop the daemon'
        'doctor:Check desktop readiness'
        'list-tools:List available tools'
        'describe:Describe a tool'
        'call:Call a tool'
        'sessions:List daemon sessions'
        'revoke:Revoke sessions'
        'permissions:Inspect permissions'
        'config:Manage configuration'
        'cursor:Configure the agent cursor'
        'cursor-theme:Manage cursor themes'
      )
      _arguments -C \
        '--help[Show help]' \
        '--version[Show version]' \
        '--socket[Daemon socket]:socket:_files' \
        '--pid-file[Daemon PID file]:file:_files' \
        '--permission-mode[Authorization mode]:mode:(standard bounded unrestricted)' \
        '--capability-manifest[Capability manifest]:file:_files' \
        '--no-overlay[Disable the agent cursor overlay]' \
        '--json[Print JSON]' \
        '1:command:->command' \
        '*:argument:_files'
      if [[ $state == command ]]; then
        _describe 'command' commands
      fi
    ''}
  '';

  meta = {
    description = "Local computer-use driver with CLI and MCP interfaces";
    homepage = "https://cua.ai/cua-driver";
    license = lib.licenses.mit;
    mainProgram = "cua-driver";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})

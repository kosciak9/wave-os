{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  installShellFiles,
  writeText,
  gcc-unwrapped,
  glib,
  libx11,
  libxi,
  libxkbcommon,
  gtk3,
  gtk4,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cua-driver";
  version = "0.64.2";

  src = fetchurl {
    url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v${finalAttrs.version}/cua-driver-rs-${finalAttrs.version}-linux-x86_64-binary.tar.gz";
    hash = "sha256-fpnUjf1z120M1QDqLIzCSRX6kKKXR5QT7am7sQnqrUg=";
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
      --set CUA_DRIVER_RS_UPDATE_CHECK false \
      --prefix PATH : ${lib.makeBinPath [ glib ]}
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
        'autostart:Manage daemon autostart'
        'doctor:Check desktop readiness'
        'test:Check a new install end to end'
        'diagnose:Print a diagnostic dump for bug reports'
        'list-tools:List available tools'
        'describe:Describe a tool'
        'call:Call a tool'
        'dump-docs:Print the docs of every tool'
        'sessions:List daemon sessions'
        'revoke:Revoke sessions'
        'connect:Connect agent clients to the driver'
        'mcp-config:Print client connection guidance'
        'manifest:Print the CLI surface as JSON'
        'recording:Start, stop or render recordings'
        'history:Manage encrypted local history'
        'permissions:Inspect permissions'
        'config:Manage configuration'
        'telemetry:Inspect or change telemetry'
        'cursor:Configure the agent cursor'
        'cursor-theme:Manage cursor themes'
        'kwin-capture:Toggle exact KWin window capture'
        'extension:Manage optional extensions'
        'perception:Parse a screenshot with the perception extension'
        'skills:Manage the agent skill pack'
        'update:Check for a newer release'
        'check-update:Check for a newer release, read-only'
        'channel:Show or set the release channel'
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

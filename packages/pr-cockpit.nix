{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  nodejs,
  autoPatchelfHook,
  writableTmpDirAsHomeHook,
  makeWrapper,
  installShellFiles,
  writeText,
  copyDesktopItems,
  makeDesktopItem,
  electron_43,
  gh,
  gitMinimal,
  curl,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  openssh,
  systemd,
  omp,
  ghostty,
  zsh,
}:

let
  pname = "pr-cockpit";
  version = "unstable-2026-10-15";
  revision = "66d8a8196c6624fbd6f9be14a9212b07b07bba3a";
  src = fetchFromGitHub {
    owner = "theolundqvist";
    repo = "pr-cockpit";
    rev = revision;
    hash = "sha256-PdoJaRGd5hMagNU1Fw1uLAHw/7B1a+iIASkBRJH/6vU=";
  };
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;
    nativeBuildInputs = [
      bun
      writableTmpDirAsHomeHook
    ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
      bun install --frozen-lockfile --ignore-scripts --no-progress
      (cd ui && bun install --frozen-lockfile --ignore-scripts --no-progress)
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R node_modules $out/root
      cp -R ui/node_modules $out/ui
      runHook postInstall
    '';
    outputHash = "sha256-ggy/F6TtxqDzysAmXgiNHEUxXElA50IuaZFlxBDOxJY=";
    outputHashMode = "recursive";
  };
  runtimePath = lib.makeBinPath [
    bun
    gh
    gitMinimal
    curl
    coreutils
    findutils
    gnugrep
    gnused
    openssh
    systemd
    omp
  ];
in
stdenvNoCC.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    bun
    nodejs
    autoPatchelfHook
    makeWrapper
    installShellFiles
    copyDesktopItems
    writableTmpDirAsHomeHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontStrip = true;

  patches = [
    ./patches/pr-cockpit-nix-electron.patch
    ./patches/pr-cockpit-appearance.patch
  ];

  postPatch = ''
    substituteInPlace scripts/cockpit \
      --replace-fail 'runtime_link="''${XDG_DATA_HOME:-$HOME/.local/share}/pr-cockpit-runtime/current"' 'runtime_link="$root"' \
      --replace-fail 'electron_bin="$runtime_root/shell/node_modules/electron/dist/electron"' 'electron_bin="${lib.getExe electron_43}"'
    cat ${./pr-cockpit-appearance.css} >> ui/src/app.css
  '';

  configurePhase = ''
    runHook preConfigure
    cp -R ${nodeModules}/root node_modules
    cp -R ${nodeModules}/ui ui/node_modules
    chmod -R u+w node_modules ui/node_modules
    rm -r ui/node_modules/@rolldown/binding-linux-x64-musl ui/node_modules/lightningcss-linux-x64-musl
    patchShebangs node_modules ui/node_modules scripts
    autoPatchelf node_modules ui/node_modules
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    (cd ui && bun run build)
    runHook postBuild
  '';

  doCheck = true;
  nativeCheckInputs = [ gitMinimal ];
  checkPhase = ''
    runHook preCheck
    bun scripts/check-release.ts
    bun scripts/check-worktree-runtime.ts
    bun test shell
    COCKPIT_DATA_DIR="$TMPDIR/pr-cockpit-check" bun test server/settings.test.ts
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    root="$out/share/pr-cockpit"
    mkdir -p "$root" "$out/bin"
    cp -R server shared scripts shell assets node_modules static package.json "$root/"
    mkdir -p "$root/ui" "$root/shell/node_modules/electron"
    cp -R ui/src "$root/ui/"
    ln -s ${electron_43}/libexec/electron "$root/shell/node_modules/electron/dist"
    for entry in pr-cockpit pr-cockpit-app; do
      script=pr-cockpit
      if [[ "$entry" == pr-cockpit-app ]]; then script=cockpit; fi
      makeWrapper "$root/scripts/$script" "$out/bin/$entry" \
        --prefix PATH : ${runtimePath} \
        --set COCKPIT_ROOT "$root" \
        --set COCKPIT_GH_BIN ${lib.getExe gh} \
        --set COCKPIT_RELEASE_REVISION ${revision} \
        --set COCKPIT_UPDATE_DISABLED 1 \
        --set COCKPIT_SENTRY_DSN "" \
        --set-default TERMINAL ${lib.getExe ghostty} \
        --set-default SHELL ${lib.getExe zsh}
    done
    install -Dm644 assets/icon.png "$out/share/icons/hicolor/512x512/apps/pr-cockpit.png"
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --zsh ${writeText "_pr-cockpit" ''
      #compdef pr-cockpit

      local context state state_descr line
      typeset -A opt_args
      local -a commands=(
        'listen:Wait for cached state changes' 'cache-run:Cache an Actions run'
        'comment:Post a PR comment' 'reply:Reply to a thread' 'resolve:Resolve a thread'
        'unresolve:Reopen a thread' 'dismiss-alert:Dismiss a CodeQL finding'
        'review:Submit a review' 'merge:Merge a PR' 'update-branch:Update the PR branch'
        'ready-for-review:Mark a draft ready' 'convert-to-draft:Convert to a draft'
        'close:Close a PR' 'edit-body:Replace the PR body'
        'edit-title:Replace the PR title' 'auto-merge:Configure GitHub auto-merge'
        'cockpit-auto-merge:Configure Cockpit auto-merge' 'inline-comment:Post an inline comment'
        'assign:Add assignees' 'unassign:Remove assignees' 'add-labels:Add labels'
        'remove-labels:Remove labels' 'request-reviewers:Request reviewers'
        'unrequest-reviewers:Remove reviewer requests' 'update:Update the app' 'status:Show server status'
      )
      _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '--jobs[Show cached Actions jobs]' \
        '--run[Select an Actions run]:run ID:' \
        '--attempt[Select a rerun attempt]:attempt:' \
        '--json[Print JSON]' \
        '--diff[Show the cached diff]' \
        '--file[Read a file at the PR head]:repository path:' \
        '--logs[Show cached unsuccessful job logs]::check:' \
        '--new-since[Only show newer comments]:date:' \
        '--ci-only[Listen only for CI changes]' \
        '--comments-only[Listen only for comments]' \
        '--conflicts-only[Listen only for conflicts]' \
        '--use-as-proxy[Use a Cockpit server over SSH]:host:_ssh_hosts' \
        '--body-file[Read comment or review text]:file:_files' \
        '--method[Merge method]:method:(squash merge rebase)' \
        '--force[Bypass Cockpit mergeability gates]' \
        '--path[Inline-comment file]:repository path:' \
        '--line[Inline-comment ending line]:line:' \
        '--side[Inline-comment side]:side:(LEFT RIGHT)' \
        '--start-line[Inline-comment starting line]:line:' \
        '--start-side[Inline-comment starting side]:side:(LEFT RIGHT)' \
        '1:command or PR reference:->command' \
        '*:argument:'
      case $state in
        command) _describe 'command' commands ;;
      esac
    ''}
    installShellCompletion --zsh ${writeText "_pr-cockpit-app" ''
      #compdef pr-cockpit-app

      _arguments \
        '(--hidden --cockpit-hidden)'{--hidden,--cockpit-hidden}'[Start hidden]' \
        '--foreground-shell[Run the desktop app in the foreground]' \
        '--show[Show the existing window]' \
        '--server-only[Run only the backend]' \
        '--managed-server[Use the managed backend]' \
        '--use-as-proxy[Use a Cockpit server over SSH]:host:_ssh_hosts' \
        '1:PR reference or prcockpit URL:'
    ''}
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "app.pr-cockpit";
      desktopName = "PR Cockpit";
      comment = "Review GitHub pull requests";
      exec = "pr-cockpit-app %u";
      icon = "pr-cockpit";
      startupWMClass = "app.pr-cockpit";
      categories = [ "Development" ];
      mimeTypes = [ "x-scheme-handler/prcockpit" ];
    })
  ];

  passthru = {
    inherit nodeModules revision;
  };

  meta = {
    description = "Keyboard-first GitHub pull request desktop client with a local cache and CLI";
    homepage = "https://github.com/theolundqvist/pr-cockpit";
    license = lib.licenses.mit;
    mainProgram = "pr-cockpit";
    platforms = [ "x86_64-linux" ];
  };
}

{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  installShellFiles,
  wayland-scanner,
  writeText,
  wrapGAppsHook4,
  gtk4,
  libadwaita,
  gtk4-layer-shell,
  wayland,
  wayland-protocols,
  ffmpeg,
  libdrm,
  pipewire,
  rubberband,
  libgbm,
  libglvnd,
  dbus,
  wireplumber,
  writableTmpDirAsHomeHook,
}:

stdenv.mkDerivation {
  pname = "waytator";
  version = "1.6.0";

  src = fetchFromGitHub {
    owner = "faetalize";
    repo = "waytator";
    rev = "4da15b0636293f1b19610da400d83a31b5efa1b8";
    hash = "sha256-u4YP5zX1pMw5Efa6b/pmcLhXNB5UbCj1gNyCDialTTU=";
  };

  patches = [ ./waytator-save-copy.patch ];
  doCheck = true;
  # Recording fixtures feed frames in real time; parallel encoders make them drop frames.
  enableParallelChecking = false;

  nativeCheckInputs = [
    dbus
    wireplumber
    writableTmpDirAsHomeHook
  ];

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    installShellFiles
    wayland-scanner
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    libadwaita
    gtk4-layer-shell
    wayland
    wayland-protocols
    ffmpeg
    libdrm
    pipewire
    rubberband
    libgbm
    libglvnd
  ];

  postInstall = ''
    installShellCompletion --zsh ${writeText "_waytator" ''
      #compdef waytator

      _arguments \
        '--stdin[Read image or video from standard input]' \
        '--name[Default name for media read from standard input]:name:' \
        '--screenshot[Capture the screen and open the result]::mode:(area screen)' \
        '--record[Record the screen and open the result]::mode:(area screen window)' \
        '--screen[Screen to capture with --screenshot or --record]:screen:' \
        '--notify[With --screenshot or --record, notify instead of opening the editor]' \
        '--delay[Wait before a screenshot or recording]:seconds:' \
        '--gapplication-service[Run as a background application service]' \
        '(--no-close-on-copy)--close-on-copy[Close after copying]' \
        '(--close-on-copy)--no-close-on-copy[Keep the window open after copying]' \
        '--close-window-shortcut[Override the close window shortcut]:shortcut:' \
        '--copy-shortcut[Override the copy shortcut]:shortcut:' \
        '--copy-without-closing-shortcut[Override the copy without closing shortcut]:shortcut:' \
        '--save-shortcut[Override the save shortcut]:shortcut:' \
        '--save-and-close-shortcut[Override the save and close shortcut]:shortcut:' \
        '--save-copy-and-close-shortcut[Override the save, copy and close shortcut]:shortcut:' \
        '--screenshot-area-shortcut[Override the capture area shortcut]:shortcut:' \
        '--screenshot-screen-shortcut[Override the capture screen shortcut]:shortcut:' \
        '--capture-area-shortcut[Override the capture area shortcut]:shortcut:' \
        '--capture-screen-shortcut[Override the capture screen shortcut]:shortcut:' \
        '(- *)'{-h,--help}'[Show help]' \
        '1:image or video:_files'
    ''}
  '';

  meta = {
    description = "Screenshot annotator and lightweight image editor";
    homepage = "https://github.com/faetalize/waytator";
    license = lib.licenses.gpl3Plus;
    mainProgram = "waytator";
    platforms = lib.platforms.linux;
  };
}

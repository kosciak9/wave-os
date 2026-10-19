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
}:

stdenv.mkDerivation {
  pname = "waytator";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "faetalize";
    repo = "waytator";
    rev = "a142d0bac7385c7394962ea3abaec780aca3460e";
    hash = "sha256-OnEUDSxKJCZsN0v2BV/QQ8ceI4BSaY9LH+QucziY1EA=";
  };

  patches = [ ./waytator-save-copy.patch ];

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
  ];

  postInstall = ''
    installShellCompletion --zsh ${writeText "_waytator" ''
      #compdef waytator

      _arguments \
        '--stdin[Read image from standard input]' \
        '--name[Default name for an image read from standard input]:name:' \
        '--screenshot[Capture the screen and open the result]::mode:(area screen)' \
        '--screen[Screen to capture with --screenshot]:screen:' \
        '--notify[With --screenshot, save, copy and notify instead of opening the editor]' \
        '--delay[With --screenshot, wait this many whole seconds first]:seconds:' \
        '--gapplication-service[Run as a background application service]' \
        '(--no-close-on-copy)--close-on-copy[Close after copying]' \
        '(--close-on-copy)--no-close-on-copy[Keep the window open after copying]' \
        '--close-window-shortcut[Override the close window shortcut]:shortcut:' \
        '--copy-shortcut[Override the copy shortcut]:shortcut:' \
        '--copy-without-closing-shortcut[Override the copy without closing shortcut]:shortcut:' \
        '--save-shortcut[Override the save shortcut]:shortcut:' \
        '--save-and-close-shortcut[Override the save and close shortcut]:shortcut:' \
        '--save-copy-and-close-shortcut[Override the save, copy and close shortcut]:shortcut:' \
        '--capture-area-shortcut[Override the capture area shortcut]:shortcut:' \
        '--capture-screen-shortcut[Override the capture screen shortcut]:shortcut:' \
        '(- *)'{-h,--help}'[Show help]' \
        '1:image:_files'
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

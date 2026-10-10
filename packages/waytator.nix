{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  installShellFiles,
  writeText,
  wrapGAppsHook4,
  gtk4,
  libadwaita,
}:

stdenv.mkDerivation {
  pname = "waytator";
  version = "1.2.4";

  src = fetchFromGitHub {
    owner = "faetalize";
    repo = "waytator";
    rev = "016023efd8f3504ddfa506a9c9b592846b59b7f4";
    hash = "sha256-kU7QRcOn49ZfYjHWVUDDvUcaosVq1H9G8NjRBHa3fRc=";
  };

  patches = [ ./waytator-save-copy.patch ];

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    installShellFiles
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    libadwaita
  ];

  postInstall = ''
    installShellCompletion --zsh ${writeText "_waytator" ''
      #compdef waytator

      _arguments \
        '--stdin[Read image from standard input]' \
        '--name[Default name for an image read from standard input]:name:' \
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

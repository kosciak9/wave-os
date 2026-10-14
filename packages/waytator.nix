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
  version = "1.2.5";

  src = fetchFromGitHub {
    owner = "faetalize";
    repo = "waytator";
    rev = "9491e3964224ac1a15e10e6b3179cf6a3635ec12";
    hash = "sha256-sv7UwNsW+UTIGLDIz4JwRpPU6t5bolsz/n4bO68dDi0=";
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

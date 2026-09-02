{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
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

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    libadwaita
  ];

  meta = {
    description = "Screenshot annotator and lightweight image editor";
    homepage = "https://github.com/faetalize/waytator";
    license = lib.licenses.gpl3Plus;
    mainProgram = "waytator";
    platforms = lib.platforms.linux;
  };
}

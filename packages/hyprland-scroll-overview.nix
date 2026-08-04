{
  lib,
  hyprland,
  pkg-config,
  src,
  version ? "unstable",
}:

hyprland.stdenv.mkDerivation {
  pname = "hyprland-scroll-overview";
  inherit version src;

  inherit (hyprland) buildInputs;
  nativeBuildInputs = hyprland.nativeBuildInputs ++ [
    hyprland
    pkg-config
  ];

  dontUseCmakeConfigure = true;

  postPatch = ''
    substituteInPlace Makefile --replace-fail lua5.4 lua
  '';

  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    export SCROLLOVERVIEW_BUILD_VERSION="${version}"
    make all
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 scrolloverview.so "$out/lib/scrolloverview.so"
    runHook postInstall
  '';

  meta = {
    description = "A scrollable overview plugin for Hyprland";
    homepage = "https://github.com/yayuuu/hyprland-scroll-overview";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}

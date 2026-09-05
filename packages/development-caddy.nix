{
  lib,
  stdenv,
  guile_3_0,
  guile-json,
  makeWrapper,
}:

stdenv.mkDerivation {
  pname = "development-caddy";
  version = "0.1.0";
  src = ./development-caddy;
  nativeBuildInputs = [
    makeWrapper
    guile_3_0
  ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p build/development-caddy
    for f in lib/development-caddy/*.scm; do
       GUILE_AUTO_COMPILE=0 guild compile -L lib -L ${guile-json}/share/guile/site/3.0 -L ${guile-json}/lib/guile/3.0/site-ccache -o build/development-caddy/$(basename ''${f%.scm}).go "$f"
    done
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/share/guile/site/3.0 $out/lib/guile/3.0/site-ccache $out/share
     cp -r lib/development-caddy $out/share/guile/site/3.0/
     cp -r build/development-caddy $out/lib/guile/3.0/site-ccache/
    cp -r static $out/share/development-caddy/
    install -Dm755 development-caddy.scm $out/bin/development-caddy
    sed -i '1c#!${guile_3_0}/bin/guile --no-auto-compile' $out/bin/development-caddy
    wrapProgram $out/bin/development-caddy \
      --set DEVELOPMENT_CADDY_STATIC $out/share/development-caddy \
      --set GUILE_LOAD_PATH $out/share/guile/site/3.0:${guile-json}/share/guile/site/3.0 \
      --set GUILE_LOAD_COMPILED_PATH $out/lib/guile/3.0/site-ccache:${guile-json}/lib/guile/3.0/site-ccache
  '';
  meta = {
    description = "Small local Development Caddy dashboard";
    mainProgram = "development-caddy";
    platforms = lib.platforms.linux;
  };
}

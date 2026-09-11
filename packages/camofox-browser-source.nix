{
  stdenvNoCC,
  fetchFromGitHub,
  jq,
  lib,
}:

stdenvNoCC.mkDerivation {
  pname = "camofox-browser-source";
  version = "1.15.0";

  src = fetchFromGitHub {
    owner = "jo-inc";
    repo = "camofox-browser";
    rev = "v1.15.0";
    hash = "sha256-YouQZa+xAWl0PL24A4eUJDb7JAMoefZBEnB+tfF3IBU=";
  };

  dontBuild = true;
  dontPatchShebangs = true;
  nativeBuildInputs = [ jq ];

  installPhase = builtins.readFile ./camofox-browser-source-install.sh;

  passthru = {
    upstreamRev = "v1.15.0";
    gitHead = "771b610a7b5994759c138b912741de58b0edd588";
  };

  meta = {
    description = "Camofox anti-detection browser and OpenClaw plugin source";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

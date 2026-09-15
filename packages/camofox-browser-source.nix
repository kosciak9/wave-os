{
  stdenvNoCC,
  fetchFromGitHub,
  jq,
  lib,
}:

let
  version = "1.15.0";
  upstreamRev = "v${version}";
  camoufox =
    {
      "aarch64-darwin" = {
        arch = "arm64";
        sha256 = "3a105a2fc929e80a79b4b7fce2c93ed62c4fb2c877f3c1ed2a5d66a1c4fe968f";
      };
      "x86_64-linux" = {
        arch = "x86_64";
        sha256 = "924f3109ccd6d47cd6a0384d67a345fadf975d48b6319f8dbbd5954c588982bd";
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "camofox-browser ${version} is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "camofox-browser-source";
  inherit version;

  src = fetchFromGitHub {
    owner = "jo-inc";
    repo = "camofox-browser";
    rev = upstreamRev;
    hash = "sha256-YouQZa+xAWl0PL24A4eUJDb7JAMoefZBEnB+tfF3IBU=";
  };

  dontBuild = true;
  dontPatchShebangs = true;
  nativeBuildInputs = [ jq ];

  installPhase =
    builtins.replaceStrings
      [ "@CAMOUFOX_ARCH@" "@CAMOUFOX_SHA256@" "@CAMOFOX_VERSION@" ]
      [
        camoufox.arch
        camoufox.sha256
        version
      ]
      (builtins.readFile ./camofox-browser-source-install.sh);

  passthru = {
    inherit upstreamRev;
    gitHead = "771b610a7b5994759c138b912741de58b0edd588";
  };

  meta = {
    description = "Camofox anti-detection browser and OpenClaw plugin source";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}

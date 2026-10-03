{
  stdenvNoCC,
  fetchFromGitHub,
  jq,
  lib,
}:

let
  version = "1.18.0";
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
    hash = "sha256-O2Lze6e6AZn/vX0QCaoS9nABpduf02pco+JDsFDP5eA=";
  };

  patches = [ ./patches/camofox-click-outcome.patch ];
  patchFlags = [
    "-p1"
    "--no-backup-if-mismatch"
  ];

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
    gitHead = "f94c81babf4bfd44cdd4bd46e1f2e1fb1d91c753";
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

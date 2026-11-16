{
  stdenvNoCC,
  fetchFromGitHub,
  jq,
  lib,
}:

let
  version = "1.19.0";
  upstreamRev = "v${version}";
  camoufox =
    {
      "aarch64-darwin" = {
        arch = "arm64";
        sha256 = "60447260af8bebdb0ec3f2aa72f687b879e5598367303de2e3fdbc7a5be8c124";
      };
      "x86_64-linux" = {
        arch = "x86_64";
        sha256 = "5720d45b894ce1770543de024c6f10d514b38be560fa2dc3226b3d8586caf672";
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
    hash = "sha256-pTfAcYBgXGCvZfxXTduqOHjx3+w0jB/zv3sPs26476E=";
  };

  patches = [
    ./patches/camofox-click-outcome.patch
    ./patches/camofox-client-errors.patch
    ./patches/camofox-health-probe-timeout.patch
  ];
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
    gitHead = "31376c27db94204ffdc635ae71a7f61328e91a5e";
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

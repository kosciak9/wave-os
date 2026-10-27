{
  stdenvNoCC,
  fetchurl,
  gnutar,
  gzip,
  darwin,
  openssl,
  autoPatchelfHook,
  glibc,
  libgcc,
  lib,
}:

let
  target =
    {
      "x86_64-linux" = {
        cli = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.2/weave-cli-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-YGF/q3A2BX1jaahRaX8JxSQMQnmk0pOWUVrB00R6TvA=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.2/weave-driver-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-6jD2uTMGOBKoOPBmDL49qNn2febitk5xAg2v/8dw9kY=";
        };
      };
      "aarch64-darwin" = {
        cli = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.2/weave-cli-aarch64-apple-darwin.tar.gz";
          hash = "sha256-p7fqbc/UBdmW6/6IM9wduatLe+J/SQDSK9r2N4z9m4E=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.2/weave-driver-aarch64-apple-darwin.tar.gz";
          hash = "sha256-NVPSHYYxUOn08Tj/PKcR3+TYwOn2AssXktWcbw9QtJY=";
        };
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "weave 0.6.2 is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "weave-merge";
  version = "0.6.2";

  src = fetchurl {
    inherit (target.cli) url hash;
  };

  driverSrc = fetchurl {
    inherit (target.driver) url hash;
  };

  nativeBuildInputs = [
    gnutar
    gzip
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isDarwin [ darwin.cctools ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    glibc
    libgcc
  ];

  unpackPhase = ''
    runHook preUnpack
    mkdir cli driver
    tar -xzf $src -C cli
    tar -xzf $driverSrc -C driver
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 cli/weave $out/bin/weave
    install -Dm755 driver/weave-driver $out/bin/weave-driver
    ${lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
      for binary in $out/bin/weave $out/bin/weave-driver; do
        install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ${openssl.out}/lib/libssl.3.dylib "$binary"
        install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib ${openssl.out}/lib/libcrypto.3.dylib "$binary"
      done
    ''}
    runHook postInstall
  '';

  meta = {
    description = "Entity-level semantic merge CLI";
    homepage = "https://github.com/Ataraxy-Labs/weave";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "weave";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}

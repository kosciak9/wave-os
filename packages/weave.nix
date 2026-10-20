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
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.1/weave-cli-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-1SiuWFF3rIVwAWz2ZF3q4WUPVF7n/PfAq3jEjmiyiPw=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.1/weave-driver-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-b4YMaAa9Ug4F08v6yAsQr78S+TnW/2Gr49/v7WxEBks=";
        };
      };
      "aarch64-darwin" = {
        cli = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.1/weave-cli-aarch64-apple-darwin.tar.gz";
          hash = "sha256-WgoHCQ8zr/s8nzTsZ8YUOcb6ab+V2pYtycRYvqQQATU=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.6.1/weave-driver-aarch64-apple-darwin.tar.gz";
          hash = "sha256-QreRpDBRhkt7WS1VH+okI0jhnkoNfHUIhJMpi8XvTZY=";
        };
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "weave 0.6.1 is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "weave-merge";
  version = "0.6.1";

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

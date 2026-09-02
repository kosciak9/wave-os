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
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.5.4/weave-cli-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-k7n6A+cUr4CR9MKKhse6gNmAPVoH0ZbEYBlgrVFCbfw=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.5.4/weave-driver-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-gjaT7IM73+HZlRLtN/9YBHwWqoF0FsZFDiOfzd69BQM=";
        };
      };
      "aarch64-darwin" = {
        cli = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.5.4/weave-cli-aarch64-apple-darwin.tar.gz";
          hash = "sha256-bogOt6A4+9I8Lo33vU3tF+6cBPvx7fyLbQM2RHmwnYc=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.5.4/weave-driver-aarch64-apple-darwin.tar.gz";
          hash = "sha256-4kSXyo563hKH0ZhtSa5EoSiY0x7Go+a/NpjllGKdE8I=";
        };
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "weave 0.5.4 is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "weave-merge";
  version = "0.5.4";

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

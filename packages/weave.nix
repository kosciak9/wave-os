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
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-cli-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-Ny194xZtPOJ+UTGMEvVzQzoMhjCThywv8qz0L4okf4I=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-driver-x86_64-unknown-linux-gnu.tar.gz";
          hash = "sha256-tjbDjUOic3bd85xOSNqkJ74fhVvMva/ERJY+dUAgZ3M=";
        };
      };
      "aarch64-darwin" = {
        cli = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-cli-aarch64-apple-darwin.tar.gz";
          hash = "sha256-HKSXj9RQkCLPdOi9euTPFAKMbfGyEw4ch2E4BImW9Tc=";
        };
        driver = {
          url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-driver-aarch64-apple-darwin.tar.gz";
          hash = "sha256-fc/OJY16pWLAAoc4facLw+IshqzC5SFDF+xre6uS2FY=";
        };
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "weave 0.3.6 is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "weave-merge";
  version = "0.3.6";

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
  ++ lib.optionals stdenvNoCC.isDarwin [ darwin.cctools ]
  ++ lib.optionals stdenvNoCC.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.isLinux [
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
    ${lib.optionalString stdenvNoCC.isDarwin ''
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

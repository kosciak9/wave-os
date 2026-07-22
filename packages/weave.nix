{
  stdenvNoCC,
  fetchurl,
  gnutar,
  gzip,
  darwin,
  openssl,
  lib,
}:

stdenvNoCC.mkDerivation {
  pname = "weave-merge";
  version = "0.3.6";

  src = fetchurl {
    url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-cli-aarch64-apple-darwin.tar.gz";
    hash = "sha256-HKSXj9RQkCLPdOi9euTPFAKMbfGyEw4ch2E4BImW9Tc=";
  };

  driverSrc = fetchurl {
    url = "https://github.com/Ataraxy-Labs/weave/releases/download/v0.3.6/weave-driver-aarch64-apple-darwin.tar.gz";
    hash = "sha256-fc/OJY16pWLAAoc4facLw+IshqzC5SFDF+xre6uS2FY=";
  };

  nativeBuildInputs = [ gnutar gzip darwin.cctools ];

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
    for binary in $out/bin/weave $out/bin/weave-driver; do
      install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib ${openssl.out}/lib/libssl.3.dylib "$binary"
      install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib ${openssl.out}/lib/libcrypto.3.dylib "$binary"
    done
    runHook postInstall
  '';

  meta = {
    description = "Entity-level semantic merge CLI";
    homepage = "https://github.com/Ataraxy-Labs/weave";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "weave";
    platforms = [ "aarch64-darwin" ];
  };
}

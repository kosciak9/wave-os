{
  fetchFromGitHub,
  installShellFiles,
  lib,
  rustPlatform,
}:

let
  mkPimalayaCli =
    {
      pname,
      version,
      hash,
      cargoHash,
      description,
    }:
    rustPlatform.buildRustPackage {
      inherit pname version cargoHash;

      src = fetchFromGitHub {
        owner = "pimalaya";
        repo = pname;
        tag = "v${version}";
        inherit hash;
      };

      nativeBuildInputs = [ installShellFiles ];
      postInstall = ''
        installShellCompletion --cmd ${pname} \
          --bash <($out/bin/${pname} completion bash) \
          --fish <($out/bin/${pname} completion fish) \
          --zsh <($out/bin/${pname} completion zsh)
      '';

      # Integration tests open sockets against live servers.
      cargoTestFlags = [ "--bins" ];

      meta = {
        inherit description;
        homepage = "https://github.com/pimalaya/${pname}";
        license = with lib.licenses; [
          asl20
          mit
        ];
        mainProgram = pname;
      };
    };
in
# neverest, calendula and cardamum share one pimdir store, so their releases
# must link the same io-pimdir version (0.5.1 here); bump them together.
{
  neverest = mkPimalayaCli {
    pname = "neverest";
    version = "0.3.0";
    hash = "sha256-nZ0qW1AIjKpmLQdXVDSHm9yedga451EF9yz3djWflJY=";
    cargoHash = "sha256-Pn7wK8+tR8qfyOR0W/RZUm+6IxlN4QjiQB5QXLXt55I=";
    description = "Synchronize mail, contacts and calendars into a local pimdir store";
  };
  calendula = mkPimalayaCli {
    pname = "calendula";
    version = "0.2.0";
    hash = "sha256-Rw9g/EdYElglrYF4VPe6xn6A4kg/WY1MFoLVP4vn1v8=";
    cargoHash = "sha256-3CwtSy8u6SKxKs8eTUgz0ctt667tfR5yB3EL1eWmn9c=";
    description = "CLI to manage calendars";
  };
  cardamum = mkPimalayaCli {
    pname = "cardamum";
    version = "0.3.0";
    hash = "sha256-2tN7RXMXTdRNlbp3h7Xb0n65skP+RaYmaCSnO2eYFfQ=";
    cargoHash = "sha256-AyeaPRxnTP8FYqrt1VNvImfje2NsILVxq17kIoOsx8M=";
    description = "CLI to manage contacts";
  };
  ortie = mkPimalayaCli {
    pname = "ortie";
    version = "2.3.0";
    hash = "sha256-1bnhWtL55k5uC5n9BoPNRPQq/l4Z54QLyqUhAjyakT4=";
    cargoHash = "sha256-UBkQiZCuyW1DWoAmv3476gKBqNKW27CVyoBScGQFR1Q=";
    description = "CLI to manage OAuth access tokens";
  };
}

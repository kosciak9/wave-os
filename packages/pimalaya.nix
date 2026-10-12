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
      patches ? [ ],
    }:
    rustPlatform.buildRustPackage {
      inherit
        pname
        version
        cargoHash
        patches
        ;

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
    patches = [
      # Google answers 404 for the series of a lone occurrence of someone
      # else's recurring event, which otherwise fails the whole calendar.
      ./patches/neverest-gcal-orphan-instances.patch
      # io-gcal puts a calendar id into the URL path unescaped, and the `#` of a
      # holiday calendar's id cuts the path short.
      ./patches/neverest-gcal-encode-calendar-id.patch
      # Gmail rate limits otherwise fail a whole fetch batch, which the next
      # run then restarts from scratch.
      ./patches/neverest-gmail-rate-limit.patch
      # The People API caps contact reads per minute, and neverest reads each
      # contact on its own.
      ./patches/neverest-gpeople-rate-limit.patch
      # An inbox move's target must reuse the Gmail message, even when it
      # syncs before the source; importing its body would duplicate it.
      ./patches/neverest-gmail-native-copy.patch
      # Access tokens expire after an hour, and a first fetch of a large
      # mailbox runs longer.
      ./patches/neverest-gmail-token-refresh.patch
      # A failed download otherwise drops every body it already fetched, so
      # the next run starts a large mailbox over.
      ./patches/neverest-keep-partial-fetch.patch
      # Gmail's All Mail is no label, so an archived message would otherwise
      # leave the store.
      ./patches/neverest-gmail-all-mail.patch
      # A Gmail message filed under several labels, ALL among them, would
      # otherwise be downloaded once per label.
      ./patches/neverest-gmail-reuse-bodies.patch
      # A large first listing raises every message's envelope in one write,
      # all lost when one request fails.
      ./patches/neverest-chunked-upgrade.patch
      # io-pimdir decodes header words in 8-bit charsets other than latin1 and
      # cp1252 as UTF-8, so Polish subjects and names lost their letters.
      ./patches/neverest-gmail-header-charsets.patch
    ];
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

{ prev, ... }:
let
  manifest = {
    version = "2.1.299";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "b510036268e62391c50f72c846319325958289283ee2dcc2b93c48f6f3c1d0ab";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "20ca25213130255bacdcae3ed5df3fc99e1d8e86cdf46e9188b7ff9c1b478fa4";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

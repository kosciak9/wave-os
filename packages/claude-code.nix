{ prev, ... }:
let
  manifest = {
    version = "2.1.306";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "5716c3679354804b7cf338de9a9c49941e53c2f3264181851f98959d7a74dd2e";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "e5a0284d14ae555ef208c6d2987e29f298cb3bb69a7497c9f24217980233acd3";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

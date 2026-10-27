{ prev, ... }:
let
  manifest = {
    version = "2.1.311";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "68a55ab38088b10f213be752ac47e2d88e81cf8ac2bae3a31396b2cd6c9a91ec";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "d0c00b80761f3030f34cf0812266f6c6f8210ff9af7242f7c6c76c5600499caf";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

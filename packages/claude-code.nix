{ prev, ... }:
let
  manifest = {
    version = "2.1.295";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "37934434b3ccd48c4fcccfb6a30a0145fffccaba8c8e935e8e3bdff0a35024a9";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "71164c85f9d226928dec7acda1baf000f1991eb14fcec106536d84bd914032f8";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

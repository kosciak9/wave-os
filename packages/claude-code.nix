{ prev, ... }:
let
  manifest = {
    version = "2.1.288";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "ba88682b23623966b04ec3639b537ef643c1d0686cc76286cc689602be8c1200";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "dc67a1d84fec13386cfc50f231211427fee5bd7b7b7f4b5a55af1a6af6f2f326";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

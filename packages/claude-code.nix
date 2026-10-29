{ prev, ... }:
let
  manifest = {
    version = "2.1.312";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "7d759495d011057b6e8b8ee911c5be3cd36e9491c71a4ab194a425cdb1418073";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "6fb9e329947c003740be888f98db1aecaa238d6c7d9ceef8581eb71d5a59480b";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

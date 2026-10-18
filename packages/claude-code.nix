{ prev, ... }:
let
  manifest = {
    version = "2.1.302";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "cd34fe7fa647e175e049207d2175fb0c3e19cc32f64f2a5be91114eca0903d15";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "2fd53245a9669ae0f826f1c4cee2e82e07f62b181b13f63b8f26c4be7cf2a4ec";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

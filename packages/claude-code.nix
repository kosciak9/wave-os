{ prev, ... }:
let
  manifest = {
    version = "2.1.304";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "d4d21e296a055068be83a9cd0753817eb5033233d6c471cc60491745766441c5";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "0f3468fa285f112650feb3bec2913425b7ba5c83cd4eb411b5c75b4086416bb6";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

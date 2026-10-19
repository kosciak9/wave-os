{ prev, ... }:
let
  manifest = {
    version = "2.1.303";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "482aa490dc1e0328bee10a163bef7f59c7c72e14de7535696b5bd3aec0089f7d";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "b00b9295b825169975983c9e1cd3eb2dbbc9c95827fa8b377a0bef0bb8b471a8";
      };
    };
  };
in
prev.claude-code.override { inherit manifest; }

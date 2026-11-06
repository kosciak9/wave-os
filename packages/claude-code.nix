{ prev, ... }:
let
  manifest = {
    version = "2.1.318";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "f49b990254804131f0be0f60260da9b4a55ec9fa73af0252816e423cb0e178dc";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "760aaca865c68a315e49d129614a5f5dc9cab99f7de75899257faed68f553f3b";
      };
    };
  };
in
(prev.claude-code.override { inherit manifest; }).overrideAttrs (old: {
  # nixpkgs defaults to the system store, which on macOS holds only keychain
  # certificates without Apple's roots, so every TLS connection fails
  # (NixOS/nixpkgs#579204). Its fix needs NIX_SSL_CERT_FILE, which launchd
  # services such as T3 lack, so add the bundled roots.
  postInstall = (old.postInstall or "") + ''
    wrapProgram $out/bin/claude --set-default CLAUDE_CODE_CERT_STORE bundled,system
  '';
})

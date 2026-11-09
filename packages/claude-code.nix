{ prev, ... }:
let
  manifest = {
    version = "2.1.321";
    platforms = {
      darwin-arm64 = {
        binary = "claude.zst";
        checksum = "2bc9e7541b21ab5a96a77b007f55211c59b5013276f14632f89ce67bf0507e01";
      };
      linux-x64 = {
        binary = "claude.zst";
        checksum = "ded331c1fbf8bdd00518599ac80a888a1d1aff3c799f3a15934adb96662094ff";
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

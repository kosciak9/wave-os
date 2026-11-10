{ claude-code }:
claude-code.overrideAttrs (old: {
  # The macOS system store holds only keychain certificates without Apple's
  # roots, so every TLS connection fails (NixOS/nixpkgs#579204). launchd
  # services such as T3 lack NIX_SSL_CERT_FILE, so add the bundled roots.
  postInstall = (old.postInstall or "") + ''
    wrapProgram $out/bin/claude --set-default CLAUDE_CODE_CERT_STORE bundled,system
  '';
})

{
  lib,
  sendspin-go,
  ffmpeg,
  installShellFiles,
}:
sendspin-go.overrideAttrs (old: {
  subPackages = [ "." ];
  # FFmpeg is used by the server's optional HLS source, not by the player.
  buildInputs = lib.remove ffmpeg old.buildInputs;
  nativeBuildInputs = old.nativeBuildInputs ++ [ installShellFiles ];
  postCheck = (old.postCheck or "") + ''
    go test ./pkg/...
  '';
  postInstall = (old.postInstall or "") + ''
    installShellCompletion --cmd sendspin-go --zsh ${./sendspin-player.zsh}
  '';
})

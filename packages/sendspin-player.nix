{
  lib,
  sendspin-go,
  fetchFromGitHub,
  ffmpeg,
  installShellFiles,
}:
sendspin-go.overrideAttrs (
  finalAttrs: old: {
    # 1.8.2 applies Music Assistant's volume and mute commands; 1.8.0 never reads them and
    # its connection stalls once they fill the command queue.
    version = "1.8.2";
    src = fetchFromGitHub {
      owner = "Sendspin";
      repo = "sendspin-go";
      tag = "v${finalAttrs.version}";
      hash = "sha256-CRo5OrcrB6ih07DcN7ofFOMb1FwzyxqFM9ksboxp+VI=";
    };
    # The player starts at volume 100 on every launch; keep the last server-set volume in
    # player.yaml so a restart does not blast an alarm at full volume.
    patches = (old.patches or [ ]) ++ [ ./sendspin-player-volume.patch ];
    subPackages = [ "." ];
    # The inherited preCheck skips TestGetLocalIPs, which 1.8.2 no longer has.
    preCheck = "";
    # FFmpeg is used by the server's optional HLS source, not by the player.
    buildInputs = lib.remove ffmpeg old.buildInputs;
    nativeBuildInputs = old.nativeBuildInputs ++ [ installShellFiles ];
    postCheck = (old.postCheck or "") + ''
      go test ./pkg/...
    '';
    postInstall = (old.postInstall or "") + ''
      installShellCompletion --cmd sendspin-go --zsh ${./sendspin-player.zsh}
    '';
  }
)

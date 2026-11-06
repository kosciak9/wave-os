{
  prev,
  fetchFromGitHub,
  installShellFiles,
}:
prev.cliproxyapi.overrideAttrs (old: {
  version = "8.0.57";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    tag = "v8.0.57";
    hash = "sha256-OS/yuyotOgYgtOArMW7t7MO16QK4xgs/O5fVncNhEy8=";
  };

  vendorHash = "sha256-02Qqrs9lQ0kE+Tnk/SWvlkLXGSh8RQPxRawFZogRYNc=";

  patches = (old.patches or [ ]) ++ [ ./patches/cliproxyapi-quota.patch ];

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

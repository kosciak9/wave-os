{
  prev,
  fetchFromGitHub,
  installShellFiles,
}:
prev.cliproxyapi.overrideAttrs (old: {
  version = "8.0.33";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    tag = "v8.0.33";
    hash = "sha256-HpsmjjMzVTnP+KcK6hy3cq3AHRsaCAVvgJdb9PKL7QU=";
  };

  vendorHash = "sha256-r3yWkdMcM40G9jV7MxW/qNv3E9WrHavFilW24quEf+8=";

  patches = (old.patches or [ ]) ++ [ ./patches/cliproxyapi-quota.patch ];

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

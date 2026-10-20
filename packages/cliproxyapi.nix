{
  prev,
  fetchFromGitHub,
  installShellFiles,
}:
prev.cliproxyapi.overrideAttrs (old: {
  version = "8.0.35";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    tag = "v8.0.35";
    hash = "sha256-XKCLx3wMlTJHGC8c0SUt/CVXzeqVEkP8s1nwV2gYZlM=";
  };

  vendorHash = "sha256-r3yWkdMcM40G9jV7MxW/qNv3E9WrHavFilW24quEf+8=";

  patches = (old.patches or [ ]) ++ [ ./patches/cliproxyapi-quota.patch ];

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

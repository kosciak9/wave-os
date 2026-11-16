{
  prev,
  fetchFromGitHub,
  installShellFiles,
}:
prev.cliproxyapi.overrideAttrs (old: {
  version = "8.0.75";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    tag = "v8.0.75";
    hash = "sha256-3FujIFPmn4s6LAMoftpnqo33gAI6R20q3v/NVLz0YNI=";
  };

  vendorHash = "sha256-GlQG6N6m2AwWn0wtM97LLKAxr2kxQTloCB8NgjUwBh4=";

  patches = (old.patches or [ ]) ++ [
    ./patches/cliproxyapi-quota.patch
    ./patches/cliproxyapi-client-model-lists.patch
    ./patches/cliproxyapi-morph-rate-limit.patch
  ];

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

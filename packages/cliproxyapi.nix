{
  prev,
  fetchFromGitHub,
  installShellFiles,
}:
prev.cliproxyapi.overrideAttrs (old: {
  version = "8.0.27";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    rev = "bf9341629ef2300ac9d846a2e80fe2756f63a671";
    hash = "sha256-AzLmUG90e746ug7NxrN6yjH9zoHLL6e91KGZZ74U5o0=";
  };

  vendorHash = "sha256-r3yWkdMcM40G9jV7MxW/qNv3E9WrHavFilW24quEf+8=";

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

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

  # subPackages limits the check phase to cmd/server, so the patched packages
  # would go untested: run their upstream tests too, so a version bump that
  # breaks a patch fails the build. In the executor package one test alone takes
  # about two minutes, so only the tests of the patched code run there.
  postCheck = (old.postCheck or "") + ''
    buildGoDir test "./internal/api ./sdk/cliproxy/auth ./sdk/api/handlers/claude ./sdk/api/handlers/openai"
    buildGoDir "test -run Meta|OpenAICompat|ApplyPatch" ./internal/runtime/executor
  '';

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh --name _cliproxyapi ${./cliproxyapi.zsh}
  '';
})

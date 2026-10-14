{
  prev,
  fetchFromGitHub,
  rustPlatform,
  ...
}:
prev.codex.overrideAttrs (
  finalAttrs: _: {
    version = "0.162.1";
    src = fetchFromGitHub {
      owner = "openai";
      repo = "codex";
      tag = "rust-v0.162.1";
      hash = "sha256-vYVQoXQdaK0bejUzcpf9uVrzNWWWAct9AsO/t261FAs=";
    };
    cargoHash = "sha256-UTu+ws1DqL375C+1jaVI9HBqDHnTuAQr7/h1rSzsEzg=";
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      sourceRoot = "${finalAttrs.src.name}/codex-rs";
      hash = finalAttrs.cargoHash;
    };
  }
)

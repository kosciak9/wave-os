{
  prev,
  fetchFromGitHub,
  rustPlatform,
  ...
}:
prev.codex.overrideAttrs (
  finalAttrs: _: {
    version = "0.160.0";
    src = fetchFromGitHub {
      owner = "openai";
      repo = "codex";
      tag = "rust-v0.160.0";
      hash = "sha256-UFPv9UK0MBYZfpZ3QlkTXa19ykHwIEo3JdwPtUUrJls=";
    };
    cargoHash = "sha256-DMRbIOynO0wGXjBxaXZJNKorD9YQv3fAoRTZ4iZEIE4=";
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      sourceRoot = "${finalAttrs.src.name}/codex-rs";
      hash = finalAttrs.cargoHash;
    };
  }
)

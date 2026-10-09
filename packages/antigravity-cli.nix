{
  prev,
  fetchurl,
  stdenvNoCC,
  ...
}:
let
  version = "1.3.2";
  buildId = "6492374831071232";
  baseUrl = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${buildId}";
  sources = {
    aarch64-darwin = {
      path = "darwin-arm/cli_mac_arm64.tar.gz";
      hash = "sha256-vdlZg73xbOtlEBfBmhjdJK9+qjzp40dNqIwlp4D4/MM=";
    };
    x86_64-linux = {
      path = "linux-x64/cli_linux_x64.tar.gz";
      hash = "sha256-ZgTm62MctpGMlybOb+pFe66YZR8MlNyeMoxueti6Y1I=";
    };
    aarch64-linux = {
      path = "linux-arm/cli_linux_arm64.tar.gz";
      hash = "sha256-IEX4IvVXuSnlTiLUeQa+SrqVWvsve7Ta/cLP2R3ZZIM=";
    };
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
in
prev.antigravity-cli.overrideAttrs (_: {
  inherit version;
  src = fetchurl {
    url = "${baseUrl}/${source.path}";
    inherit (source) hash;
  };
  passthru = (prev.antigravity-cli.passthru or { }) // {
    wholeVersion = "${version}-${buildId}";
  };
})

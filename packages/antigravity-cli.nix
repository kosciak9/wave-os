{
  prev,
  fetchurl,
  stdenvNoCC,
  ...
}:
let
  version = "1.2.16";
  buildId = "5594158052802560";
  baseUrl = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${buildId}";
  sources = {
    aarch64-darwin = {
      path = "darwin-arm/cli_mac_arm64.tar.gz";
      hash = "sha256-l7A+o+kJFuDIpJ7ephVAb47GkEfd4XIopHjBhURF0yo=";
    };
    x86_64-linux = {
      path = "linux-x64/cli_linux_x64.tar.gz";
      hash = "sha256-1CR0MOBM69vhypPZzLSDzS89rrTNsKzlpxzRMOC9q4Q=";
    };
    aarch64-linux = {
      path = "linux-arm/cli_linux_arm64.tar.gz";
      hash = "sha256-ptJp0nZOVjarK82nO3jFh/6dAOrXZ6o5dFdCKVhe4NM=";
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

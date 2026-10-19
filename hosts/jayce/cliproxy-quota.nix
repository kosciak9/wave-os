{
  lib,
  pkgs,
  osConfig,
  ...
}:

let
  # Prints the gateway's quota snapshot so callers never handle the key.
  cliproxyQuota = pkgs.writeShellApplication {
    name = "cliproxy-quota";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      key=$(< ${lib.escapeShellArg osConfig.sops.secrets."cliproxyapi/quota-key".path})
      base_url=$(< ${lib.escapeShellArg osConfig.sops.secrets."cliproxyapi/base-url".path})
      base_url="''${base_url%/}"
      if [[ -z "$key" || "$base_url" != https://* ]]; then
        printf 'cliproxy-quota requires a quota key and HTTPS base URL in SOPS.\n' >&2
        exit 1
      fi
      fetch() {
        # The header comes from a builtin, so the key never appears in argv.
        curl --fail-with-body --silent --show-error --max-time 30 \
          --header @<(printf 'Authorization: Bearer %s\n' "$key") \
          "$base_url/v1/quota"
      }
      # A request answers from the cache and starts a refresh of stale accounts.
      snapshot=$(fetch)
      for _ in {1..12}; do
        jq --exit-status 'any(.accounts[]; .stale)' <<< "$snapshot" > /dev/null || break
        sleep 5
        snapshot=$(fetch)
      done
      jq . <<< "$snapshot"
    '';
  };
in
{
  home.packages = [ cliproxyQuota ];
  programs.zsh.generatedCompletions.cliproxy-quota = "printf '%s\\n' '#compdef cliproxy-quota' '_gnu_generic'";
}

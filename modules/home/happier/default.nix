{ pkgs, ... }:
let
  relayUrl = "https://renekton.dusky-diatonic.ts.net:18443";
in
{
  home.packages = [ pkgs.happier ];
  home.sessionVariables = {
    HAPPIER_SERVER_URL = relayUrl;
    HAPPIER_WEBAPP_URL = relayUrl;
  };
}

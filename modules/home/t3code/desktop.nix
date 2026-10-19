{ lib, pkgs, ... }:
let
  settings = pkgs.writeText "t3code-desktop-settings.json" (
    builtins.toJSON (import ./desktop-settings.nix)
  );
  desktop = pkgs.symlinkJoin {
    name = "t3code-desktop-configured";
    paths = [ pkgs.t3code-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/t3code-desktop" --set T3CODE_NIX_CONFIG ${settings}
      rm "$out/share/applications/t3code.desktop"
      substitute ${pkgs.t3code-desktop}/share/applications/t3code.desktop \
        "$out/share/applications/t3code.desktop" \
        --replace-fail ${lib.getExe pkgs.t3code-desktop} "$out/bin/t3code-desktop"
    '';
    inherit (pkgs.t3code-desktop) meta;
  };
in
{
  home.packages = [ desktop ];
  # The app registers its own handler under the unwrapped binary, without the Nix settings.
  xdg.mimeApps.defaultApplications."x-scheme-handler/t3code" = [ "t3code.desktop" ];
}

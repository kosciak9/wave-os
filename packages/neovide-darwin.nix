{
  lib,
  neovide,
  runCommand,
}:

let
  icon = ../assets/neovide/Neovide.icns;
in
runCommand "${neovide.pname}-darwin-${neovide.version}"
  {
    meta = neovide.meta // {
      platforms = lib.platforms.darwin;
    };
  }
  ''
    mkdir -p "$out/Applications" "$out/bin"
    cp -R --no-dereference ${neovide}/Applications/Neovide.app "$out/Applications/"

    app="$out/Applications/Neovide.app"
    chmod -R u+w "$app/Contents/Resources"
    rm "$app/Contents/Resources/Neovide.icns"
    install -m 0444 ${icon} "$app/Contents/Resources/Neovide.icns"

    ln -s ${neovide}/bin/neovide "$out/bin/neovide"
  ''

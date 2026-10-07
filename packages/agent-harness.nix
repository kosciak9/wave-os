{
  lib,
  makeBinaryWrapper,
  runCommand,
}:
# Gives an agent harness its own Camofox identity; --set overrides an identity
# inherited from a parent harness.
package: camofoxUser:
let
  program = package.meta.mainProgram;
in
runCommand "${package.pname}-${package.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    inherit (package)
      pname
      version
      passthru
      meta
      ;
  }
  ''
    mkdir -p $out/bin $out/libexec
    ln -s ${package}/bin/* $out/bin/
    rm $out/bin/${program}
    ln -s ${lib.getExe package} $out/libexec/${program}
    makeBinaryWrapper $out/libexec/${program} $out/bin/${program} \
      --argv0 ${program} \
      --set CAMOFOX_USER_ID ${camofoxUser}
    if [ -d ${package}/share ]; then
      ln -s ${package}/share $out/share
    fi
  ''

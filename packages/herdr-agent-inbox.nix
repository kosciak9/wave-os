{
  lib,
  stdenvNoCC,
  python3,
  coreutils,
  gnugrep,
  procps,
  src,
}:
stdenvNoCC.mkDerivation {
  pname = "herdr-agent-inbox";
  version = "0.1.0";
  inherit src;
  nativeBuildInputs = [ python3 ];
  patches = [ ./patches/herdr-agent-inbox-title-owner.patch ];
  postPatch = ''
    substituteInPlace scripts/ensure-daemon.sh scripts/restart-daemon.sh \
      --replace-fail 'nohup python3' '${coreutils}/bin/nohup ${python3}/bin/python3 -B'
    for script in scripts/ensure-daemon.sh scripts/restart-daemon.sh; do
      substituteInPlace "$script" --replace-fail '#!/bin/sh' '#!${stdenvNoCC.shell}
    export PATH=${
      lib.makeBinPath (
        [
          coreutils
          gnugrep
        ]
        ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ procps ]
      )
    }:/usr/bin:/bin'
    done
    substituteInPlace actions.py \
      --replace-fail '["/bin/sh", os.path.join(here, "scripts", "ensure-daemon.sh")]' \
        '["${stdenvNoCC.shell}", os.path.join(here, "scripts", "ensure-daemon.sh")]'
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 - <<'PY'
    import ast, pathlib
    for name in ("daemon.py", "actions.py", "inbox_tui.py"):
        ast.parse(pathlib.Path(name).read_text(), filename=name)
    PY
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp daemon.py actions.py inbox_tui.py "$out/"
    cp -r scripts "$out/"
    runHook postInstall
  '';
}

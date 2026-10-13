{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  glib,
  gtk4,
  gtksourceview5,
  poppler,
  fontconfig,
  gst_all_1,
  gdk-pixbuf,
  ffmpeg,
  ffmpegthumbnailer,
  imagemagick,
  libraw,
  squashfsTools,
  util-linux,
  installShellFiles,
  writeText,
  wrapGAppsHook4,
  coreutils,
  dbus,
  xvfb-run,
}:

rustPlatform.buildRustPackage {
  pname = "strata";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "lgse";
    repo = "strata";
    rev = "0a086aa3bdb251842a1e8413e2a6b35970d0b409";
    hash = "sha256-dFNsFCnkeZs0VwmYRyu+6Jh8XxJzv+agUlP70Fdxa5Q=";
  };

  cargoHash = "sha256-vuhHierqb4WsMdg890NpkaztYnfsnck2FxMz5cPMwCQ=";

  nativeBuildInputs = [
    pkg-config
    glib
    installShellFiles
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    gtksourceview5
    poppler
    fontconfig
    gdk-pixbuf
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-libav
  ];

  nativeCheckInputs = [
    dbus
    ffmpeg
    xvfb-run
  ];

  postPatch = ''
    substituteInPlace src/services/update_install/review_tests.rs \
      src/services/update_install/manifest/tests.rs \
      --replace-fail /bin/true ${coreutils}/bin/true
    substituteInPlace src/sandbox/tests.rs \
      --replace-fail /bin/cat ${coreutils}/bin/cat
    substituteInPlace src/trusted_command.rs \
      --replace-fail '    "/usr/sbin",' '    "${coreutils}/bin",'
    substituteInPlace src/portal/dbus/tests.rs \
      --replace-fail '"--session"' '"--config-file=${dbus}/share/dbus-1/session.conf"'
  '';

  env = {
    CARGO_PROFILE_RELEASE_LTO = "off";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
    STRATA_BUILD_COMMIT = "0a086aa3bdb251842a1e8413e2a6b35970d0b409";
    STRATA_SANDBOX_ROOT = "/nix/store";
    STRATA_SANDBOX_PRLIMIT = "${util-linux}/bin/prlimit";
    STRATA_SANDBOX_GDK_PIXBUF_MODULE_FILE = "${gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
    STRATA_SANDBOX_PATH = lib.makeBinPath [
      ffmpeg
      ffmpegthumbnailer
      imagemagick
      libraw
      squashfsTools
    ];
  };

  checkPhase = ''
    runHook preCheck
    export HOME=$(mktemp -d)
    export GTK_A11Y=none
    export STRATA_REQUIRE_GTK_TESTS=1
    dbus-run-session --config-file=${dbus}/share/dbus-1/session.conf -- xvfb-run -a \
      cargo test --offline --release --target ${stdenv.hostPlatform.rust.rustcTarget} \
      -- --test-threads="$NIX_BUILD_CORES"
    runHook postCheck
  '';

  postInstall = ''
    install -Dm644 data/io.github.lgse.Strata.desktop \
      "$out/share/applications/io.github.lgse.Strata.desktop"
    substituteInPlace "$out/share/applications/io.github.lgse.Strata.desktop" \
      --replace-fail 'Exec=strata ' "Exec=$out/bin/strata "
    install -Dm644 data/icons/scalable/apps/io.github.lgse.Strata.svg \
      "$out/share/icons/hicolor/scalable/apps/io.github.lgse.Strata.svg"
    install -Dm644 data/io.github.lgse.Strata.FileManager1.service \
      "$out/share/dbus-1/services/io.github.lgse.Strata.FileManager1.service"
    substituteInPlace "$out/share/dbus-1/services/io.github.lgse.Strata.FileManager1.service" \
      --replace-fail /usr/bin/strata "$out/bin/strata"
    install -Dm644 ${writeText "strata-install-source.toml" ''
      manager = "Nix"
      channel = "stable"
    ''} "$out/share/strata/install-source.toml"

    installShellCompletion --zsh ${writeText "_strata" ''
      #compdef strata

      _arguments \
        '--version[Print the installed version]' \
        '--help[Show help]' \
        '--unlock-volume[Unlock an encrypted volume]:device:_files -W /dev' \
        '*:directory:_files -/'
    ''}
  '';

  meta = {
    description = "Fast, keyboard-first file manager for Linux";
    homepage = "https://stratafiles.io";
    license = [
      lib.licenses.mit
      lib.licenses.unfreeRedistributable
    ];
    mainProgram = "strata";
    platforms = lib.platforms.linux;
  };
}

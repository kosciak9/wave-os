{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  glib,
  gsettings-desktop-schemas,
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
  coreutils-full,
  bubblewrap,
  gnutar,
  procps,
  python3,
  shared-mime-info,
  tzdata,
  dbus,
  xvfb-run,
  vmTools,
}:

let
  buildEnv = {
    CARGO_PROFILE_RELEASE_LTO = "off";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
    TZDIR = "${tzdata}/share/zoneinfo";
    STRATA_BUILD_COMMIT = "be3343a5992a2a5497b1a2ee7faa525be18e988f";
    STRATA_SANDBOX_ROOT = "/nix/store";
    STRATA_SANDBOX_PRLIMIT = "${util-linux}/bin/prlimit";
    STRATA_SANDBOX_GDK_PIXBUF_MODULE_FILE = "${gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
    STRATA_TRUSTED_COMMAND_PATH = lib.makeBinPath [
      coreutils
      bubblewrap
      gnutar
      python3
    ];
    STRATA_SANDBOX_PATH = lib.makeBinPath [
      ffmpeg
      ffmpegthumbnailer
      imagemagick
      libraw
      squashfsTools
    ];
  };
  package = rustPlatform.buildRustPackage {
    pname = "strata";
    version = "1.1.1";
    memSize = 16384;
    enableParallelBuilding = true;
    QEMU_OPTS = "-serial file:xchg/serial.log -monitor none";
    preVM = ''
      trap 'tr -d "\r" < xchg/serial.log' EXIT
    '';

    src = fetchFromGitHub {
      owner = "lgse";
      repo = "strata";
      rev = "be3343a5992a2a5497b1a2ee7faa525be18e988f";
      hash = "sha256-mWFYDKlVR6/LytRBGmgZlWX70N+Qlt3Ev5W5TmJ8UdE=";
    };

    cargoHash = "sha256-+8Ztfdf/523VTH4nozy9b5Fde+GTk0xWRMbBUBA5rKs=";
    # Only the package builds as root inside the VM, not the vendor fetcher.
    depsExtraArgs.preUnpack = "";

    nativeBuildInputs = [
      pkg-config
      glib
      installShellFiles
      wrapGAppsHook4
    ];

    buildInputs = [
      gtk4
      gsettings-desktop-schemas
      gtksourceview5
      poppler
      fontconfig
      shared-mime-info
      gdk-pixbuf
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gst_all_1.gst-libav
    ];

    nativeCheckInputs = [
      dbus
      ffmpeg
      imagemagick
      procps
      python3
      util-linux
      xvfb-run
    ];

    preUnpack = ''
      chmod 755 /
      mkdir /build
      cd /build
      export NIX_BUILD_TOP=/build
      export TMPDIR=/build
    '';

    postPatch = ''
      substituteInPlace src/services/update_install/review_tests.rs \
        src/services/update_install/manifest/tests.rs \
        --replace-fail /bin/true ${coreutils-full.override { singleBinary = false; }}/bin/true
      substituteInPlace src/sandbox/tests.rs \
        --replace-fail /bin/cat ${coreutils}/bin/cat
      # Release-profile tests must retain the UI-thread guard they exercise.
      substituteInPlace src/util/ui_thread.rs \
        --replace-fail '    debug_assert!(' $'    #[cfg(any(test, debug_assertions))]\n    assert!('
      substituteInPlace src/services/file_providers/tests.rs src/ui/file_providers/tests.rs \
        --replace-fail /usr/bin/python3 /build/test-python3
      substituteInPlace src/portal/dbus/tests.rs \
        --replace-fail '"--session"' '"--config-file=${dbus}/share/dbus-1/session.conf"'
    '';

    env = buildEnv;

    checkPhase = ''
      runHook preCheck
      export HOME=/build/test-home
      export TMPDIR=/build/test-tmp
      mkdir -p "$HOME" "$TMPDIR"
      # virtiofs exposes store files as nobody; provider checks require a root-owned shell.
      cp -L /bin/sh /build/test-sh
      mv -T /build/test-sh /bin/sh
      ln -s ${gnutar}/bin/tar /bin/tar
      cp -L ${python3}/bin/python3 /build/test-python3
      chmod 755 /build
      chown -R 1000:100 "$PWD" "$HOME" "$TMPDIR"
      echo 'nixbld:x:1000:100:Nix build user:/build/test-home:/bin/sh' >> /etc/passwd
      echo 'nixbld:x:100:' >> /etc/group
      export XDG_DATA_DIRS="${shared-mime-info}/share:$GSETTINGS_SCHEMAS_PATH:''${XDG_DATA_DIRS:-}"
      export GTK_A11Y=none
      export STRATA_REQUIRE_GTK_TESTS=1
      setpriv --reuid=1000 --regid=100 --clear-groups \
        dbus-run-session --config-file=${dbus}/share/dbus-1/session.conf -- \
        xvfb-run -a -s '-screen 0 1280x1024x24 -nolisten tcp -noreset' \
        cargo test --offline --release --target ${stdenv.hostPlatform.rust.rustcTarget} \
        -- --test-threads=1
      runHook postCheck
    '';

    preFixup = ''
      gappsWrapperArgs+=(--prefix XDG_DATA_DIRS : "${shared-mime-info}/share")
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
  };
in
# The upstream checks need real file ownership, user namespaces and extended attributes.
lib.overrideDerivation (vmTools.runInLinuxVM package) (attrs: {
  env = buildEnv // attrs.env;
})

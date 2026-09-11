{
  lib,
  stdenv,
}:

assert lib.assertMsg stdenv.hostPlatform.isDarwin "mac-apps-mcp-host is only supported on Darwin";

stdenv.mkDerivation {
  pname = "mac-apps-mcp-host";
  version = "1.0.0";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    cat > mac-apps-mcp-host.c <<'EOF'
    #include <errno.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <unistd.h>

    static volatile sig_atomic_t child_pid = -1;
    static void forward_signal(int signal_number) {
      pid_t pid = child_pid;
      if (pid > 0) (void)kill(pid, signal_number);
    }

    int main(int argc, char **argv) {
      if (argc < 2) {
        dprintf(STDERR_FILENO, "Mac Apps MCP Host: child executable is required\n");
        dprintf(STDERR_FILENO, "usage: %s CHILD [ARGS ...]\n", argv[0]);
        return 64;
      }
      struct sigaction action = {0};
      action.sa_handler = forward_signal;
      sigemptyset(&action.sa_mask);
      if (sigaction(SIGTERM, &action, NULL) == -1 ||
          sigaction(SIGINT, &action, NULL) == -1 ||
          sigaction(SIGHUP, &action, NULL) == -1) {
        dprintf(STDERR_FILENO, "Mac Apps MCP Host: could not install signal handlers: %s\n",
                strerror(errno));
        return EXIT_FAILURE;
      }
      pid_t pid = fork();
      if (pid == -1) {
        dprintf(STDERR_FILENO, "Mac Apps MCP Host: could not spawn child: %s\n", strerror(errno));
        return EXIT_FAILURE;
      }
      if (pid == 0) {
        execvp(argv[1], &argv[1]);
        dprintf(STDERR_FILENO, "Mac Apps MCP Host: could not execute '%s': %s\n",
                argv[1], strerror(errno));
        _exit(127);
      }
      child_pid = pid;
      int status;
      pid_t waited;
      do {
        waited = waitpid(pid, &status, 0);
      } while (waited == -1 && errno == EINTR);
      child_pid = -1;
      if (waited == -1) {
        dprintf(STDERR_FILENO, "Mac Apps MCP Host: could not wait for child: %s\n", strerror(errno));
        return EXIT_FAILURE;
      }
      if (WIFEXITED(status)) return WEXITSTATUS(status);
      if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
      return EXIT_FAILURE;
    }
    EOF
    $CC -Wall -Wextra -Werror -O2 -o mac-apps-mcp-host mac-apps-mcp-host.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Mac Apps MCP Host.app"
    mkdir -p "$app/Contents/MacOS"
    cp mac-apps-mcp-host "$app/Contents/MacOS/Mac Apps MCP Host"
    chmod 0555 "$app/Contents/MacOS/Mac Apps MCP Host"
    cat > "$app/Contents/Info.plist" <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Mac Apps MCP Host</string>
      <key>CFBundleIdentifier</key><string>ai.openclaw.mac-apps-mcp-host</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundleName</key><string>Mac Apps MCP Host</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>1.0.0</string>
      <key>CFBundleVersion</key><string>1.0.0</string>
      <key>LSUIElement</key><true/>
    </dict></plist>
    EOF
    /usr/bin/codesign --force --sign - --identifier ai.openclaw.mac-apps-mcp-host "$app"
    /usr/bin/codesign --verify --deep --strict "$app"
    runHook postInstall
  '';

  meta = {
    description = "Stable signed app host for the Mac Apps MCP server";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
}

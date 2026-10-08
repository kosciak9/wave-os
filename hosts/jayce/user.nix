{
  config,
  lib,
  pkgs,
  ...
}:

let
  kosciakAvatar = pkgs.stdenvNoCC.mkDerivation {
    pname = "kosciak-avatar";
    version = "1";
    src = ./assets/profile-picture.jpeg;
    nativeBuildInputs = [ pkgs.imagemagick ];
    dontUnpack = true;
    installPhase = ''
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.imagemagick}/bin/magick "$src" \
        -auto-orient \
        -resize 512x512^ \
        -gravity north \
        -extent 512x512 \
        "$out/avatar.png"
    '';
  };

  # Runs after each rejected hyprlock password. Counts failures per hyprlock
  # process, so every lock starts afresh: three fast tries, then 2, 4, 8, 16
  # and at most 30 seconds before the next one.
  hyprlockFailDelay = pkgs.writeShellApplication {
    name = "wave-hyprlock-fail-delay";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      dir="/run/user/$(id -u)/hyprlock-auth-failures"
      mkdir -p "$dir"
      for file in "$dir"/*; do
        [[ -e $file ]] || continue
        pid="''${file##*/}"
        [[ -d /proc/''${pid%%-*} ]] || rm -f "$file"
      done

      read -r -a stat <"/proc/$PPID/stat"
      # The start time keeps a reused PID from inheriting another lock's count.
      file="$dir/$PPID-''${stat[21]}"
      count=$(($(cat "$file" 2>/dev/null || echo 0) + 1))
      echo "$count" >"$file"

      ((count > 3)) || exit 0
      delay=2
      for ((i = 4; i < count && delay < 30; i++)); do
        delay=$((delay * 2))
      done
      sleep $((delay > 30 ? 30 : delay))
    '';
  };
in
{
  # Fingerprints unlock only the lock screen, where hyprlock reads them beside
  # the password field; a PAM fingerprint prompt would hold the password back.
  options.security.pam.services = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule { config.fprintAuth = lib.mkDefault false; });
  };

  config = {
    services.accounts-daemon.enable = true;
    services.fprintd.enable = true;
    programs.ydotool.enable = true;

    # GDM fingerprints cannot decrypt the login keyring; require a typed password there.
    programs.dconf.profiles.gdm.databases = [
      {
        settings."org/gnome/login-screen".enable-fingerprint-authentication = false;
        locks = [ "/org/gnome/login-screen/enable-fingerprint-authentication" ];
      }
    ];

    security = {
      soteria.enable = true;
      pam.services.hyprlock = {
        nodelay = true;
        rules.auth = {
          # Only a wrong password reaches the delay; aborted conversations fail at once.
          unix.control = lib.mkForce "[success=done new_authtok_reqd=done auth_err=ignore default=die]";
          fail-delay = {
            order = config.security.pam.services.hyprlock.rules.auth.unix.order + 10;
            control = "optional";
            modulePath = "${pkgs.linux-pam}/lib/security/pam_exec.so";
            args = [
              "quiet"
              (lib.getExe hyprlockFailDelay)
            ];
          };
        };
      };
    };

    users.users.kosciak = {
      isNormalUser = true;
      description = "Franek Madej";
      shell = pkgs.zsh;
      extraGroups = [
        "audio"
        "libvirtd"
        "networkmanager"
        "video"
        "wheel"
        "ydotool"
      ];
    };

    systemd.services.kosciak-avatar = {
      description = "Set the kosciak AccountsService avatar";
      wantedBy = [ "multi-user.target" ];
      wants = [ "accounts-daemon.service" ];
      after = [ "accounts-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        object_path=$(${pkgs.systemd}/bin/busctl --system call \
          org.freedesktop.Accounts \
          /org/freedesktop/Accounts \
          org.freedesktop.Accounts \
          FindUserByName \
          s kosciak | ${pkgs.gnused}/bin/sed -nE 's/^[[:space:]]*o "([^"]+)".*$/\1/p')

        if [ -z "$object_path" ]; then
          ${pkgs.coreutils}/bin/printf '%s\n' "AccountsService returned no user object path" >&2
          exit 1
        fi

        ${pkgs.systemd}/bin/busctl --system call \
          org.freedesktop.Accounts \
          "$object_path" \
          org.freedesktop.Accounts.User \
          SetIconFile \
          s \
          "${kosciakAvatar}/avatar.png"
      '';
    };
  };
}

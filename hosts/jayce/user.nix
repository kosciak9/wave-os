{ pkgs, ... }:

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
in
{
  services.accounts-daemon.enable = true;
  services.fprintd.enable = true;

  # GDM fingerprints cannot decrypt the login keyring; require a typed password there.
  programs.dconf.profiles.gdm.databases = [
    {
      settings."org/gnome/login-screen".enable-fingerprint-authentication = false;
      locks = [ "/org/gnome/login-screen/enable-fingerprint-authentication" ];
    }
  ];

  security = {
    soteria.enable = true;
    pam.services.hyprlock.fprintAuth = true;
    # Keep terminal sudo authentication password-only despite global fingerprint support.
    pam.services.sudo.fprintAuth = false;
  };

  users.users.kosciak = {
    isNormalUser = true;
    description = "Franek Madej";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "networkmanager"
      "video"
      "wheel"
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
}

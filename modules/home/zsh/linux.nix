{
  programs.zsh = {
    oh-my-zsh.plugins = [ "systemd" ];

    shellAliases = {
      caffeinate = "echo 'preventing idle and lid sleep' && systemd-inhibit --what=idle:sleep:handle-lid-switch --who=caffeinate --why=Caffeinate sleep infinity";
      cp = "cp -rv --reflink=auto";
      sc-suspend = "systemctl suspend";
    };
  };
}

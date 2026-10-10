{
  programs.zsh = {
    oh-my-zsh.plugins = [ "systemd" ];

    shellAliases = {
      caffeinate = "wave caffeinate on";
      decaffeinate = "wave caffeinate off";
      cp = "cp -rv --reflink=auto";
      sc-suspend = "systemctl suspend";
    };
  };
}

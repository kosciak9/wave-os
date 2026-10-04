{
  programs.zsh = {
    oh-my-zsh.plugins = [ "systemd" ];

    shellAliases = {
      caffeinate = "systemctl --user start wave-caffeinate.service";
      decaffeinate = "systemctl --user stop wave-caffeinate.service";
      cp = "cp -rv --reflink=auto";
      sc-suspend = "systemctl suspend";
    };
  };
}

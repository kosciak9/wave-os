{
  config,
  pkgs,
  ...
}:

{
  home.packages = [ pkgs.jankyborders ];

  programs.aerospace = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ./aerospace.toml);
    launchd = {
      enable = true;
      keepAlive = true;
    };
  };

  # Startup commands such as borders need the user profile in launchd's PATH.
  launchd.agents.aerospace.config.EnvironmentVariables.PATH =
    "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
}

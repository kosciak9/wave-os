{
  config,
  pkgs,
  ...
}:

{
  home.packages = with pkgs; [
    aerospace
    jankyborders
  ];

  home.file.".aerospace.toml" = {
    source = ./aerospace.toml;
    force = true;
  };

  launchd.agents.aerospace = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [
        "${pkgs.aerospace}/Applications/AeroSpace.app/Contents/MacOS/AeroSpace"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables.PATH =
        "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
  };
}

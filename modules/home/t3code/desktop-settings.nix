{
  desktopSettings.localEnvironmentEnabled = false;
  clientSettings = {
    fontFamilySans = "Overpass";
    fontFamilyCode = "Overpass Mono";
    fontFamilyComposer = "Overpass Nerd Font Propo";
    followUpBehavior = "steer";
    appearanceContrast = 160;
    panelAnimationDurationMs = 25;
    diffColorScheme = "blue-orange";
    notificationMode = "notifications-and-sound";
    inAppNotificationsEnabled = true;
    persistComposerContextStrip = true;
    sidebarProjectGroupingMode = "separate";
  };
  theme = import ./kanagawa-dragon.nix;
}

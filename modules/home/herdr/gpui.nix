{ inputs, pkgs, ... }:
{
  home.packages = [
    (inputs.herdr-gpui.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./patches/gpui-shortcut-hints.patch
        ./patches/gpui-worktree-no-branch.patch
      ];
    }))
  ];

  # Settings saves replace this symlink; edit preferences here instead of in the GUI.
  xdg.configFile."herdr/config-gpui.local.toml" = {
    force = true;
    source = (pkgs.formats.toml { }).generate "herdr-gpui-settings" {
      show_system_load = false;
      agent_checkpoints = false;
      theme = "light:kanagawa,dark:kanagawa";
      layout = {
        mode = "superset";
        sidebar_gap = 8.0;
      };
      terminal.family = "Overpass Mono";
      sidebar.family = "Overpass";
      tabs.family = "Overpass";
      ui.family = "Overpass";
      sidebar.hosts = {
        Local = "#2B3328";
        renekton = "#2D4F67";
        ahri = "#49443C";
      };
      palette.project_roots = [
        "~/Developer/alergeek"
        "~/Developer/personal"
      ];
      # Linux terminal conventions instead of the Super-based defaults, which
      # Hyprland owns. Copy, cut, paste and select-all stay hard-coded to Super.
      keybindings = {
        new_tab = "ctrl-shift-t";
        new_worktree = "ctrl-shift-n";
        new_workspace = "ctrl-alt-shift-n";
        new_window = "";
        open_notification_target = "ctrl-alt-n";
        split_right = "ctrl-shift-o";
        split_down = "ctrl-shift-e";
        split_editor = "ctrl-alt-e";
        next_tab = [
          "ctrl-tab"
          "ctrl-pagedown"
        ];
        previous_tab = [
          "ctrl-shift-tab"
          "ctrl-pageup"
        ];
        focus_left = "ctrl-alt-left";
        focus_right = "ctrl-alt-right";
        focus_up = "ctrl-alt-up";
        focus_down = "ctrl-alt-down";
        next_pane = "ctrl-alt-]";
        previous_pane = "ctrl-alt-[";
        toggle_zoom = "ctrl-shift-enter";
        clear_pane = "ctrl-shift-k";
        find = "ctrl-shift-f";
        copy_mode = "ctrl-shift-space";
        close_pane = "ctrl-shift-w";
        close_tab = "ctrl-alt-shift-w";
        toggle_sidebar = "ctrl-shift-b";
        increase_font_size = [
          "ctrl-="
          "ctrl-+"
        ];
        decrease_font_size = "ctrl--";
        reset_font_size = "ctrl-0";
        settings = "ctrl-,";
        keybindings = "ctrl-shift-h";
        sessions = "ctrl-shift-s";
        workspace_picker = "ctrl-shift-l";
        command_palette = "ctrl-shift-p";
        quit = "ctrl-shift-q";
        # Built-in daemon chords shadow plugin commands here, unlike in the TUI;
        # free prefix+shift+r for the Worktrunk remote-branch picker.
        reload_config = "";
      }
      // builtins.listToAttrs (
        map (n: {
          name = "focus_tab_${toString n}";
          value = "alt-${toString n}";
        }) (builtins.genList (n: n + 1) 9)
      );
    };
  };
}

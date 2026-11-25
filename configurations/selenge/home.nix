# Agent instructions and skills for AV sandboxes (as `dev`) and their coordinator (as
# `coordinator`) on Ubuntu with multi-user Nix. The coordinator activates this for whichever
# user runs it, so the identity comes from the environment (evaluate with --impure).
# It owns opencode.json(c) and the Git identity there, and has no user session.
{ pkgs, ... }:
let
  earshot = pkgs.callPackage ../../packages/earshot.nix { };
  earshotSkills = pkgs.callPackage ../../packages/earshot-skills.nix { inherit earshot; };
in
{
  home = {
    username = builtins.getEnv "USER";
    homeDirectory = builtins.getEnv "HOME";
    stateVersion = "26.11";
    # The earshot and real-sound skills run these.
    packages = [
      earshot
      pkgs.ffmpeg
    ];
  };

  # Every sandbox activates this, so leave out what Home Manager adds by default but nothing
  # here uses: systemd (there is no user session), man-db, MIME data and every glibc locale.
  systemd.user.enable = false;
  programs.man.enable = false;
  xdg.mime.enable = false;
  manual.manpages.enable = false;
  i18n.glibcLocales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };
  news.display = "silent";

  home.file = {
    ".agents/skills" = {
      source = ../../modules/home/agents/skills;
      recursive = true;
      force = true;
    };
    ".agents/skills/earshot".source = "${earshotSkills}/earshot";
    ".agents/skills/real-sound".source = "${earshotSkills}/real-sound";
  };
  # Only the pieces that need nothing from the wave-os hosts: no T3 Code, no model routing
  # through cliproxy, no *.wave.exposed previews and no worktrunk.
  xdg.configFile."opencode/AGENTS.md" = {
    text = import ../../modules/home/agents/instructions [
      "managed"
      "communication"
      "execution"
      "delegation"
      "ui-changes"
      "evidence"
      "transcribed-messages"
    ];
    force = true;
  };
}

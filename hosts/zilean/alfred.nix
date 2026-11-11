# Alfred's stack runs as a user of its own, so kosciak's agents, scheduled tasks and dev
# containers cannot read his secrets, logins or Podman volumes.
{ lib, pkgs, ... }:

let
  uid = 1001;
in
{
  users = {
    users = {
      alfred = {
        # A uid above 999 gives his user services a journal of their own (`journalctl --user`).
        inherit uid;
        isSystemUser = true;
        group = "alfred";
        home = "/var/lib/alfred";
        createHome = true;
        homeMode = "700";
        # Administered with `sudo machinectl shell alfred@`.
        shell = pkgs.zsh;
        linger = true;
        # Rootless Podman. The allocator keeps automatic ranges apart; explicit ones it does not reserve.
        autoSubUidGidRange = true;
      };
      # With createHome, every activation chmods kosciak's existing home to 0700, which empties its
      # ACL mask and takes alfred's passage to the vault (below) away; tmpfiles reapplies it only
      # when its rules change.
      kosciak.createHome = lib.mkForce false;
    };
    groups.alfred.gid = uid;
  };

  sops.secrets =
    lib.genAttrs
      [
        "alfred/env"
        "alfred/prompt.md"
        "alfred/mcp-token"
        "alfred/anytype-api-key"
        "alfred/anytype-space-id"
        "alfred/obsidian-vault-path"
        "alfred/google-workspace-client.json"
        "alfred/google-workspace-email"
        "alfred/twenty-mcp-url"
        "alfred/twenty-api-key"
        "alfred/substack-publication-url"
        "alfred/substack-session-token"
        "alfred/x-session.json"
        "alfred/openrouter-api-key"
        "camofox/vnc-password"
        "protonmail/address"
        "protonmail/bridge-password"
        "slack-mirror/mcp-token"
        "slack-mirror/session.json"
      ]
      (_: {
        owner = "alfred";
      });

  # His services and rootless containers all run in his user slice. Its MemoryLow keeps his
  # steady state (agent, bridges, Proton Mail Bridge, Anytype) resident when builds and agents
  # press on memory; MemoryHigh throttles his bursts (Gotenberg alone may take 2G, Camofox and
  # LanguageTool more) before they push kosciak's work out. A cgroup's protection is capped by
  # its ancestors', so user.slice carries it too; its other children share none of it.
  systemd.slices = {
    user.sliceConfig.MemoryLow = "1536M";
    "user-${toString uid}" = {
      overrideStrategy = "asDropin";
      sliceConfig = {
        MemoryLow = "1536M";
        MemoryHigh = "5G";
      };
    };
  };

  # His Obsidian bridge edits the vault Syncthing keeps in kosciak's home: alfred may only pass
  # through to it, and files either of them creates stay editable by the other. A chmod narrows
  # the mask, so zilean's Syncthing ignores permissions in this folder (set at runtime); m::
  # restores the mask at the next boot or switch.
  systemd.tmpfiles.rules = [
    "a+ /home/kosciak - - - - u:alfred:--x"
    "a+ /home/kosciak/Documents - - - - u:alfred:--x"
    "A+ /home/kosciak/Documents/zk - - - - u:alfred:rwX,u:kosciak:rwX,m::rwX,d:u:alfred:rwX,d:u:kosciak:rwX,d:g::---"
  ];

  home-manager.users.alfred = {
    imports = [
      ../../modules/home/alfred
      ../../modules/home/frida
      ../../modules/home/slack-mirror
      ../../modules/home/zsh
      ../../modules/home/zsh/linux.nix
    ];
    home.stateVersion = "26.11";
  };
}

# Merged into each server's settings.json; T3 keeps every other key.
{ profileDirectory }:
{
  favorites = [
    {
      provider = "codex";
      model = "gpt-6.1-sol";
    }
    {
      provider = "claudeAgent";
      model = "claude-opus-5-5";
    }
    {
      provider = "opencode";
      model = "cliproxy/gpt-6.1-sol";
    }
  ];
  defaultModelSelection = {
    instanceId = "claudeAgent";
    model = "claude-opus-5-5";
  };
  providerInstances = {
    claudeAgent = {
      driver = "claudeAgent";
      enabled = true;
      config.binaryPath = "${profileDirectory}/bin/claude";
    };
    opencode = {
      driver = "opencode";
      displayName = "OpenCode";
      enabled = true;
    };
  };
  defaultThreadEnvMode = "worktree";
  # Shared with Worktrunk's worktree-path, so T3 and `wt` manage one tree.
  worktreesDirectory = "~/Developer/worktrees";
  # T3 appends the old location on change; `<T3 home>/worktrees` stays managed regardless.
  previousWorktreesDirectories = [ ];
  defaultAutoPull = true;
  defaultProjectScripts = [
    {
      id = "worktree-setup";
      name = "Set up worktree";
      command = builtins.readFile ./worktree-setup.sh;
      icon = "configure";
      runOnWorktreeCreate = true;
      async = false;
    }
    {
      id = "worktree-teardown";
      name = "Tear down worktree";
      command = builtins.readFile ./worktree-teardown.sh;
      icon = "configure";
      runOnWorktreeCreate = false;
      runOnSettle = true;
    }
  ];
  worktreeCleanup.mode = "off";
  storageCleanup.worktreeSettledAfterDays = 7;
  enableAgentBrowserAccess = false;
  snoozeLimitedThreads = true;
  autoResumeLimitedThreads = true;
  sidebarAutoSettleAfterDays = null;
  sidebarAutoSettleOnMerge = false;
  branchNameInstructions = "";
}

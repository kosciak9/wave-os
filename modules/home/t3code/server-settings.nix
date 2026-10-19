# Merged into each server's settings.json; T3 keeps every other key.
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
    };
    opencode = {
      driver = "opencode";
      displayName = "OpenCode";
      enabled = true;
    };
  };
  defaultThreadEnvMode = "worktree";
  defaultAutoPull = true;
  worktreeCleanup.mode = "off";
  storageCleanup.worktreeSettledAfterDays = 7;
  enableAgentBrowserAccess = false;
  snoozeLimitedThreads = true;
  autoResumeLimitedThreads = true;
  sidebarAutoSettleAfterDays = null;
  sidebarAutoSettleOnMerge = false;
  branchNameInstructions = "";
}

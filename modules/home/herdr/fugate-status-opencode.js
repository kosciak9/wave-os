import { spawn } from "node:child_process";

const STATUS_HOOK = "@statusHook@";

function lastAssistantText(messages) {
  const message = messages.findLast((item) => item.type === "assistant");
  if (!message) return undefined;
  return message.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

function runStatusHook(text) {
  const hook = spawn(STATUS_HOOK, [], { stdio: ["pipe", "ignore", "ignore"] });
  hook.on("error", () => {});
  hook.stdin.on("error", () => {});
  hook.stdin.end(JSON.stringify({ last_assistant_message: text }));
}

export default {
  id: "fugate.status",
  setup(api) {
    if (process.env.HERDR_ENV !== "1" || !process.env.HERDR_SOCKET_PATH || !process.env.HERDR_PANE_ID) return;

    // A TUI may share its server with other panes; report only the root
    // session this pane shows, never sub-agent or foreign sessions.
    function shownRoot(sessionID) {
      const route = api.ui.router.current();
      return route.type === "session" && api.data.session.root(route.sessionID) === sessionID;
    }

    return api.data.on("session.execution.succeeded", async (event) => {
      const sessionID = event.data.sessionID;
      if (!shownRoot(sessionID)) return;
      let text = lastAssistantText(api.data.session.message.list(sessionID));
      if (text === undefined) {
        await api.data.session.message.sync(sessionID).catch(() => {});
        text = lastAssistantText(api.data.session.message.list(sessionID));
      }
      if (text) runStatusHook(text);
    });
  },
};

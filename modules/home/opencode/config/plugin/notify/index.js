import { execFile, spawn } from "node:child_process";
import { basename } from "node:path";

const MIN_DURATION_SECONDS = 0;
const PERMISSION_DEDUPE_MS = 1000;
const IDLE_COMPLETE_DELAY_MS = 350;

const MESSAGES = {
  permission: "Permission requested: {details}",
  complete: "Turn complete: {sessionTitle}",
  subagent_complete: "Subagent complete: {sessionTitle}",
  error: "Error: {details}",
  interrupted: "Interrupted: {sessionTitle}",
  user_cancelled: "Cancelled: {sessionTitle}",
  question: "Question: {sessionTitle}",
  plan_exit: "Plan ready: {sessionTitle}",
  session_started: "Session started: {sessionTitle}",
  client_connected: "OpenCode connected",
};

const pendingIdleTimers = new Map();
const subagentSessionIDs = new Set();
const permissionLastSeenBySession = new Map();
let permissionLastSeenAt = 0;

function asRecord(value) {
  return value && typeof value === "object" ? value : {};
}

function getString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function getEventSessionID(event) {
  return getString(asRecord(event.properties).sessionID);
}

function getLifecycleInfo(event) {
  const info = asRecord(asRecord(event.properties).info);
  return {
    id: getString(info.id),
    title: getString(info.title),
    parentID: getString(info.parentID),
  };
}

async function getSessionInfo(client, sessionID) {
  if (!sessionID) return { isChild: false, title: null };

  try {
    const response = await client.session.get({ path: { id: sessionID } });
    return {
      isChild: Boolean(response.data?.parentID),
      title: getString(response.data?.title),
    };
  } catch {
    return { isChild: false, title: null };
  }
}

async function getElapsedSinceLastPrompt(client, sessionID, nowMs = Date.now()) {
  if (!sessionID || MIN_DURATION_SECONDS <= 0) return null;

  try {
    const response = await client.session.messages({ path: { id: sessionID } });
    const messages = response.data ?? [];
    let lastUserMessageTime = null;

    for (const message of messages) {
      const info = message.info;
      if (info?.role === "user" && typeof info.time?.created === "number") {
        lastUserMessageTime = Math.max(lastUserMessageTime ?? 0, info.time.created);
      }
    }

    return lastUserMessageTime === null ? null : (nowMs - lastUserMessageTime) / 1000;
  } catch {
    return null;
  }
}

function shouldSuppressByDuration(eventType, elapsedSeconds) {
  if (MIN_DURATION_SECONDS <= 0) return false;
  if (eventType !== "complete" && eventType !== "subagent_complete") return false;
  return typeof elapsedSeconds === "number" && elapsedSeconds < MIN_DURATION_SECONDS;
}

function shouldSuppressPermission(sessionID, now = Date.now()) {
  const sessionLastSeenAt = sessionID ? permissionLastSeenBySession.get(sessionID) : undefined;
  const lastSeenAt = Math.max(permissionLastSeenAt, sessionLastSeenAt ?? 0);

  if (lastSeenAt > 0 && now - lastSeenAt < PERMISSION_DEDUPE_MS) {
    return true;
  }

  permissionLastSeenAt = now;
  if (sessionID) permissionLastSeenBySession.set(sessionID, now);
  return false;
}

function extractAgentName(sessionTitle) {
  const match = sessionTitle?.match(/\s*\(@([^\s)]+)\s+subagent\)\s*$/);
  return match?.[1] ?? "";
}

function formatTimestamp() {
  const now = new Date();
  return [now.getHours(), now.getMinutes(), now.getSeconds()]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");
}

function formatMessage(eventType, context = {}) {
  const template = MESSAGES[eventType] ?? eventType;
  const replacements = {
    event: eventType,
    sessionTitle: context.sessionTitle ?? "",
    agentName: context.agentName ?? "",
    projectName: context.projectName ?? "",
    timestamp: context.timestamp ?? "",
    details: context.details ?? "",
  };

  return Object.entries(replacements)
    .reduce((result, [key, value]) => result.replaceAll(`{${key}}`, value), template)
    .replace(/\s*[:-]\s*$/u, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function notificationTitle(projectName) {
  return projectName ? `OpenCode (${projectName})` : "OpenCode";
}

function notificationStage(eventType) {
  return {
    permission: "Permission requested",
    complete: "Turn complete",
    subagent_complete: "Subagent complete",
    error: "Error",
    interrupted: "Interrupted",
    user_cancelled: "Cancelled",
    question: "Question",
    plan_exit: "Plan ready",
    session_started: "Session started",
    client_connected: "OpenCode connected",
  }[eventType] ?? "OpenCode";
}

function appleScriptString(value) {
  return `"${String(value).replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

async function notifyMac(projectName, message) {
  const script = `display notification ${appleScriptString(message)} with title ${appleScriptString(notificationTitle(projectName))}`;

  await new Promise((resolve) => {
    execFile("osascript", ["-e", script], () => resolve());
  });
}

function notifyLinux(projectName, eventType, message) {
  const child = spawn("qs", ["-c", "wave", "ipc", "call", "opencode", "notify", projectName ?? "", notificationStage(eventType), message], {
    detached: true,
    stdio: "ignore",
  });

  child.on("error", () => {});
  child.unref();
}

async function sendNotification(eventType, projectName, message) {
  if (process.platform === "darwin") {
    await notifyMac(projectName, message);
    return;
  }

  if (process.platform === "linux") {
    notifyLinux(projectName, eventType, message);
  }
}

async function handleEvent(client, eventType, projectName, options = {}) {
  const sessionID = options.sessionID ?? null;
  let sessionTitle = options.sessionTitle ?? null;

  if (!sessionTitle && sessionID) {
    const sessionInfo = await getSessionInfo(client, sessionID);
    sessionTitle = sessionInfo.title;
  }

  const elapsedSeconds = await getElapsedSinceLastPrompt(client, sessionID, options.elapsedReferenceNowMs);
  if (shouldSuppressByDuration(eventType, elapsedSeconds)) return;

  const agentName = extractAgentName(sessionTitle);
  const message = formatMessage(eventType, {
    sessionTitle,
    agentName,
    projectName,
    timestamp: formatTimestamp(),
    details: options.details,
  });

  await sendNotification(eventType, projectName, message);
}

function permissionDetails(value) {
  const record = asRecord(value);
  const properties = asRecord(record.properties ?? value);
  const permission = getString(properties.permission) ?? getString(record.permission) ?? "permission";
  const patterns = Array.isArray(properties.patterns)
    ? properties.patterns.filter((pattern) => typeof pattern === "string")
    : [];

  return patterns.length > 0 ? `${permission} - ${patterns.join(", ")}` : permission;
}

function errorDetails(event) {
  const error = asRecord(asRecord(event.properties).error);
  return getString(error.message) ?? getString(error.name) ?? "session error";
}

function errorEventType(event) {
  const error = asRecord(asRecord(event.properties).error);
  const name = getString(error.name) ?? "";

  if (name === "MessageAbortedError") return "user_cancelled";
  if (/interrupt/i.test(name)) return "interrupted";
  return "error";
}

function clearIdleTimer(sessionID) {
  const timer = pendingIdleTimers.get(sessionID);
  if (!timer) return;

  clearTimeout(timer);
  pendingIdleTimers.delete(sessionID);
}

function scheduleIdle(client, projectName, event, sessionID) {
  if (!sessionID) {
    void handleEvent(client, "complete", projectName, { elapsedReferenceNowMs: Date.now() });
    return;
  }

  clearIdleTimer(sessionID);

  const idleReceivedAtMs = Date.now();
  const timer = setTimeout(() => {
    pendingIdleTimers.delete(sessionID);
    void processIdle(client, projectName, event, sessionID, idleReceivedAtMs);
  }, IDLE_COMPLETE_DELAY_MS);

  pendingIdleTimers.set(sessionID, timer);
}

async function processIdle(client, projectName, event, sessionID, idleReceivedAtMs) {
  if (subagentSessionIDs.has(sessionID)) {
    await handleEvent(client, "subagent_complete", projectName, {
      sessionID,
      elapsedReferenceNowMs: idleReceivedAtMs,
    });
    return;
  }

  const sessionInfo = await getSessionInfo(client, sessionID);
  if (sessionInfo.isChild) {
    subagentSessionIDs.add(sessionID);
    await handleEvent(client, "subagent_complete", projectName, {
      sessionID,
      sessionTitle: sessionInfo.title,
      elapsedReferenceNowMs: idleReceivedAtMs,
    });
    return;
  }

  await handleEvent(client, "complete", projectName, {
    sessionID,
    sessionTitle: sessionInfo.title,
    elapsedReferenceNowMs: idleReceivedAtMs,
  });
}

export const NotifyPlugin = async ({ client, directory }) => {
  const projectName = directory ? basename(directory) : "";

  setTimeout(() => {
    void handleEvent(client, "client_connected", projectName);
  }, 100);

  return {
    event: async ({ event }) => {
      if (event.type === "session.created") {
        const info = getLifecycleInfo(event);
        if (info.parentID && info.id) {
          subagentSessionIDs.add(info.id);
          return;
        }

        await handleEvent(client, "session_started", projectName, {
          sessionID: info.id,
          sessionTitle: info.title,
        });
        return;
      }

      if (event.type === "session.updated") {
        const info = getLifecycleInfo(event);
        if (info.parentID && info.id) subagentSessionIDs.add(info.id);
        return;
      }

      if (event.type === "session.deleted") {
        const info = getLifecycleInfo(event);
        if (info.id) {
          subagentSessionIDs.delete(info.id);
          clearIdleTimer(info.id);
        }
        return;
      }

      if (event.type === "permission.asked") {
        const sessionID = getEventSessionID(event);
        if (shouldSuppressPermission(sessionID)) return;

        await handleEvent(client, "permission", projectName, {
          sessionID,
          details: permissionDetails(event),
        });
        return;
      }

      if (event.type === "session.idle") {
        scheduleIdle(client, projectName, event, getEventSessionID(event));
        return;
      }

      if (event.type === "session.status") {
        const properties = asRecord(event.properties);
        const status = asRecord(properties.status);
        const sessionID = getString(properties.sessionID);

        if (status.type === "busy" && sessionID) {
          clearIdleTimer(sessionID);
          return;
        }

        if (status.type === "idle") {
          scheduleIdle(client, projectName, event, sessionID);
        }
        return;
      }

      if (event.type === "session.error") {
        const sessionID = getEventSessionID(event);
        clearIdleTimer(sessionID);

        await handleEvent(client, errorEventType(event), projectName, {
          sessionID,
          details: errorDetails(event),
        });
        return;
      }

      if (event.type === "session.interrupted") {
        await handleEvent(client, "interrupted", projectName, {
          sessionID: getEventSessionID(event),
        });
      }
    },

    "permission.ask": async (input) => {
      const record = asRecord(input);
      const sessionID = getString(record.sessionID);
      if (shouldSuppressPermission(sessionID)) return;

      await handleEvent(client, "permission", projectName, {
        sessionID,
        details: permissionDetails(input),
      });
    },

    "tool.execute.before": async (input) => {
      if (input.tool === "question") {
        await handleEvent(client, "question", projectName, { sessionID: input.sessionID });
        return;
      }

      if (input.tool === "plan_exit") {
        await handleEvent(client, "plan_exit", projectName, { sessionID: input.sessionID });
      }
    },
  };
};

export default NotifyPlugin;

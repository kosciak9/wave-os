import { execFile, spawn } from "node:child_process";
import { basename } from "node:path";

const PERMISSION_DEDUPE_MS = 1000;
const permissionLastSeenBySession = new Map();
let permissionLastSeenAt = 0;

function asRecord(value) {
  return value && typeof value === "object" ? value : {};
}

function getString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
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

function permissionDetails(value) {
  const record = asRecord(value);
  const properties = asRecord(record.properties ?? value);
  const permission = getString(properties.permission) ?? getString(record.permission) ?? "permission";
  const patterns = Array.isArray(properties.patterns)
    ? properties.patterns.filter((pattern) => typeof pattern === "string")
    : [];

  return patterns.length > 0 ? `${permission} - ${patterns.join(", ")}` : permission;
}

function notificationTitle(projectName) {
  return projectName ? `OpenCode (${projectName})` : "OpenCode";
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

function notifyLinux(projectName, message) {
  const child = spawn("qs", ["-c", "wave", "ipc", "call", "opencode", "notify", projectName, "Permission requested", message], {
    detached: true,
    stdio: "ignore",
  });

  child.on("error", () => {});
  child.unref();
}

export async function sendPermissionNotification({ directory, request }) {
  const record = asRecord(request);
  const sessionID = getString(record.sessionID);
  if (shouldSuppressPermission(sessionID)) return;

  const projectName = directory ? basename(directory) : "";
  const message = `Permission requested: ${permissionDetails(request)}`
    .replace(/\s*[:-]\s*$/u, "")
    .replace(/\s{2,}/g, " ")
    .trim();

  if (process.platform === "darwin") {
    await notifyMac(projectName, message);
    return;
  }

  if (process.platform === "linux") {
    notifyLinux(projectName, message);
  }
}

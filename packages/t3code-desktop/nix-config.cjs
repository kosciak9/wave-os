const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { app, ipcMain, session } = require("electron");

const configPath = process.env.T3CODE_NIX_CONFIG;
if (configPath) {
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const stateDirectory = path.join(
    process.env.T3CODE_HOME || path.join(os.homedir(), ".t3"),
    "userdata",
  );

  // Nix owns selected preferences; T3 retains every other key and all credentials.
  for (const [filename, preferences] of [
    ["desktop-settings.json", config.desktopSettings],
    ["client-settings.json", config.clientSettings],
  ]) {
    const preference = path.join(stateDirectory, filename);
    const destination = fs.existsSync(preference)
      ? fs.realpathSync(preference)
      : preference;
    const current = fs.existsSync(destination)
      ? JSON.parse(fs.readFileSync(destination, "utf8"))
      : {};
    if (!current || typeof current !== "object" || Array.isArray(current)) {
      throw new Error(
        `Refusing to replace malformed T3 Code preferences: ${filename}`,
      );
    }
    const next = { ...current, ...preferences };
    if (JSON.stringify(current) === JSON.stringify(next)) continue;
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    const temporary = `${destination}.nix-${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify(next, null, 2)}\n`, {
      mode: 0o600,
    });
    fs.renameSync(temporary, destination);
  }

  ipcMain.on("wave-os:t3code-theme", (event) => {
    event.returnValue = event.senderFrame?.url.startsWith("t3code://app/")
      ? config.theme
      : null;
  });
  app.whenReady().then(() => {
    session.defaultSession.registerPreloadScript({
      type: "frame",
      filePath: path.join(process.resourcesPath, "nix-preload.cjs"),
    });
  });
}

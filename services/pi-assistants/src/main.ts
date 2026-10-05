import { readFile, mkdir } from "node:fs/promises";
import { createServer } from "node:http";
import { Bot } from "grammy";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { configuredModels, parseConfig } from "./config.js";
import { openRuntime } from "./runtime.js";
import { openDurableDatabase } from "./storage.js";

function fatal(reason: string): never {
  console.error(reason);
  // Do not call bot.stop here: it confirms grammY's last *tried* update,
  // which may not yet have been durably admitted.
  process.exit(1);
}

async function main() {
  process.umask(0o077);
  const config = parseConfig(
    JSON.parse(
      await readFile(process.env.PI_CONFIG_FILE ?? "/run/config.json", "utf8"),
    ),
  );
  const models = await configuredModels(config);
  await mkdir("/state", { recursive: true, mode: 0o700 });
  const bot = new Bot(config.botToken);
  await bot.init();
  const storage = await SqliteStorage.open(
    await openDurableDatabase("/state/pi.sqlite"),
  );
  const runtime = await openRuntime({
    config,
    botId: bot.botInfo.id,
    storage,
    models,
    api: bot.api,
    fatal,
  });
  let admission: Promise<unknown> | undefined;
  let ready = false;
  let stopping = false;
  bot.use(async (ctx) => {
    admission = runtime.admit(ctx.update);
    try {
      await admission;
    } catch {
      // Failed storage admission poisons the Pi session: recover by restarting,
      // leaving this update unconfirmed instead of retrying a broken session.
      fatal("admission_failure");
    } finally {
      admission = undefined;
    }
  });
  bot.catch(() => fatal("polling_middleware_failure"));
  const health = createServer((request, response) => {
    if (request.url !== "/healthz") {
      response.writeHead(404).end();
      return;
    }
    response
      .writeHead(ready && !stopping ? 200 : 503, {
        "Content-Type": "text/plain",
      })
      .end(ready && !stopping ? "ready\n" : "not ready\n");
  });
  health.on("error", () => fatal("health_server_failure"));
  await new Promise<void>((resolve) =>
    health.listen(8080, "127.0.0.1", resolve),
  );
  const polling = bot
    .start({
      drop_pending_updates: false,
      allowed_updates: ["message"],
      onStart: () => {
        ready = !stopping;
      },
    })
    .catch(() => fatal("polling_failure"));
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    ready = false;
    const timeout = setTimeout(() => process.exit(0), 25_000);
    timeout.unref();
    // stop() synchronously captures the last tried offset. No confirmation until
    // that admission commits; then polling drains the remaining fetched batch
    // before storage closes. A failed admission exits without further confirmation.
    while (admission) await admission;
    await bot.stop();
    await polling;
    await runtime.close();
    await new Promise<void>((resolve) => health.close(() => resolve()));
    clearTimeout(timeout);
  };
  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.once(signal, () => {
      void shutdown().catch(() => fatal("shutdown_failure"));
    });
  }
  await polling;
}

process.on("uncaughtException", () => fatal("uncaught_failure"));
process.on("unhandledRejection", () => fatal("unhandled_failure"));
void main().catch(() => fatal("startup_failure"));

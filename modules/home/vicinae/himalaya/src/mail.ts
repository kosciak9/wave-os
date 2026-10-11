import { execFile } from "node:child_process";
import { z } from "zod";
import { messageMarkdown } from "./body";
export { escapeMarkup } from "./body";

const accountSchema = z.object({
  name: z.string().min(1),
  backends: z.array(z.string()),
  default: z.boolean(),
});
const addressSchema = z.object({
  name: z.string().nullable(),
  email: z.string(),
});
const envelopeSchema = z.object({
  id: z.string().min(1),
  subject: z.string(),
  from: z.array(addressSchema),
  date: z.string().nullable(),
  flags: z.array(z.object({ raw: z.string(), iana: z.string().nullable() })),
});
const accountsSchema = z.object({ accounts: z.array(accountSchema) });
const pageSchema = z.object({ envelopes: z.array(envelopeSchema) });
const archiveSchema = z.object({
  action: z.literal("archived"),
  count: z.literal(1),
});
const moveSchema = z.object({
  message: z.literal("1 message successfully moved"),
});
const queueStatusSchema = z.object({ pending: z.number().int().nonnegative() });

export type Account = z.infer<typeof accountSchema>;
export type Mail = z.infer<typeof envelopeSchema> & {
  account: Account;
  mailbox: "inbox";
  key: string;
};
export type AccountInbox = {
  account: Account;
  messages: Mail[];
  error: string | null;
};
export type WriteStatus =
  | { status: "remote" }
  | { status: "syncing" }
  | { status: "pending"; message: string };

function run(
  file: string,
  args: string[],
  timeout = 60_000,
  maxBuffer = 16 * 1024 * 1024,
) {
  return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
    execFile(
      file,
      args,
      { encoding: "utf8", timeout, maxBuffer },
      (error, stdout, stderr) => {
        if (error) {
          // CLI diagnostics can contain authentication data or message bodies.
          let message = `${file} failed; check its configuration or service status`;
          if (error.killed) {
            message = `${file} timed out; outcome may be uncertain`;
          } else if (file === "himalaya") {
            if (
              /not downloaded yet \(body not fetched\)|Body blob missing for/.test(
                stderr,
              )
            ) {
              message =
                "Message body is unavailable in the local mirror; sync the account and retry";
            } else if (stderr.includes("Failed to parse RFC 5322 message")) {
              message = "Himalaya could not parse this message's MIME content";
            }
          }
          reject(new Error(message));
        } else {
          resolve({ stdout, stderr });
        }
      },
    );
  });
}

async function json(args: string[]): Promise<unknown> {
  const { stdout } = await run("himalaya", ["--json", ...args]);
  try {
    const parsed: unknown = JSON.parse(stdout);
    return parsed;
  } catch {
    throw new Error("Himalaya returned invalid JSON");
  }
}

export async function listAccounts(): Promise<Account[]> {
  const parsed = accountsSchema.safeParse(await json(["account", "list"]));
  if (!parsed.success)
    throw new Error(
      "Unsupported Himalaya account JSON; version 2.2.1 is required",
    );
  return parsed.data.accounts;
}

export async function loadInbox(account: Account): Promise<AccountInbox> {
  const messages = new Map<string, Mail>();
  const pageSize = 200;
  try {
    for (let page = 1; ; page++) {
      const parsed = pageSchema.safeParse(
        await json([
          "--account",
          account.name,
          "envelope",
          "list",
          "--mailbox",
          "inbox",
          "--page-size",
          String(pageSize),
          "--page",
          String(page),
        ]),
      );
      if (!parsed.success)
        throw new Error("Unsupported Himalaya envelope JSON");
      const previousSize = messages.size;
      for (const envelope of parsed.data.envelopes) {
        const key = JSON.stringify([account.name, "inbox", envelope.id]);
        messages.set(key, { ...envelope, account, mailbox: "inbox", key });
      }
      if (parsed.data.envelopes.length < pageSize) break;
      if (messages.size === previousSize)
        throw new Error("Inbox pagination did not advance; refresh to retry");
    }
    return { account, messages: [...messages.values()], error: null };
  } catch (error) {
    return {
      account,
      messages: [...messages.values()],
      error: errorText(error),
    };
  }
}

export function errorText(error: unknown): string {
  return error instanceof Error
    ? error.message
    : "Unexpected mail operation failure";
}

export function isSeen(message: Mail): boolean {
  return message.flags.some((flag) => flag.iana === "seen");
}

export function sender(message: Mail): string {
  return (
    message.from.map((address) => address.name || address.email).join(", ") ||
    "Unknown sender"
  );
}

export async function refreshBadge(): Promise<boolean> {
  try {
    await run(
      "qs",
      ["-c", "wave", "ipc", "call", "mail", "refresh"],
      5_000,
      1024 * 1024,
    );
    return true;
  } catch {
    return false;
  }
}

export async function confirmWrite(account: Account): Promise<WriteStatus> {
  if (!account.backends.includes("pimdir")) return { status: "remote" };
  try {
    const unit = `neverest-sync@${account.name}.service`;
    const { stdout } = await run(
      "systemctl",
      ["--user", "show", unit, "--property=ActiveState,Result,ExecMainStatus"],
      5_000,
      1024 * 1024,
    );
    const properties = new Map(
      stdout
        .trim()
        .split("\n")
        .map((line) => {
          const separator = line.indexOf("=");
          return [line.slice(0, separator), line.slice(separator + 1)];
        }),
    );
    // A running sync is no failure: a first fill runs for hours, and it
    // drains the queue as it starts.
    if (properties.get("ActiveState") !== "inactive") return { status: "syncing" };
    if (
      properties.get("Result") !== "success" ||
      properties.get("ExecMainStatus") !== "0"
    ) {
      return {
        status: "pending",
        message:
          "The last sync failed or left unresolved work. Remote application is not confirmed.",
      };
    }
    const queue = queueStatusSchema.safeParse(
      await json(["--account", account.name, "pimdir", "queue", "status"]),
    );
    if (!queue.success) throw new Error("Unsupported raw queue status JSON");
    if (queue.data.pending === 0) return { status: "remote" };
    return {
      status: "pending",
      message:
        "Changed locally; raw queue actions are still pending. Remote application is not confirmed.",
    };
  } catch {
    return {
      status: "pending",
      message:
        "Unable to confirm sync and raw queue status. The write may still be queued.",
    };
  }
}

// A full account sync takes minutes, so the write is handed to it rather than
// awaited; reopening the inbox confirms it through confirmWrite.
async function flushWrite(account: Account): Promise<WriteStatus> {
  if (!account.backends.includes("pimdir")) return { status: "remote" };
  try {
    await run(
      "systemctl",
      ["--user", "start", "--no-block", `neverest-sync@${account.name}.service`],
      10_000,
      1024 * 1024,
    );
    return { status: "syncing" };
  } catch {
    return {
      status: "pending",
      message: "Changed locally; the sync could not be started. The write stays queued.",
    };
  }
}

export async function readMail(message: Mail): Promise<{
  body: string;
  seenLocally: boolean;
  confirmation: Promise<{ write: WriteStatus | null; badgeRefreshed: boolean }>;
}> {
  if (message.account.backends.length === 0)
    throw new Error(
      "Himalaya did not identify this account's backend; patched account discovery is required",
    );
  const alreadySeen = isSeen(message);
  const { stdout, stderr } = await run(
    "himalaya",
    [
      "--json",
      "--account",
      message.account.name,
      "message",
      "read",
      "--mailbox",
      message.mailbox,
      ...(alreadySeen ? [] : ["--seen"]),
      "--",
      message.id,
    ],
    60_000,
    64 * 1024 * 1024,
  );
  const seenLocally = !stderr.includes("could not stage");
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new Error("Himalaya returned invalid message JSON");
  }
  return {
    body: messageMarkdown(parsed),
    seenLocally,
    confirmation: (async () => {
      const write: WriteStatus | null = alreadySeen
        ? null
        : !seenLocally
          ? {
              status: "pending",
              message:
                "Message opened, but marking it seen could not be queued.",
            }
          : await flushWrite(message.account);
      return { write, badgeRefreshed: await refreshBadge() };
    })(),
  };
}

export async function archiveMail(
  message: Mail,
): Promise<{ write: WriteStatus; badgeRefreshed: boolean }> {
  if (message.account.backends.length === 0)
    throw new Error(
      "Himalaya did not identify this account's backend; patched account discovery is required",
    );
  const report = archiveSchema.safeParse(
    await json([
      "--account",
      message.account.name,
      "message",
      "archive",
      "--",
      message.id,
    ]),
  );
  if (!report.success)
    throw new Error(
      "Archive response did not confirm one processed message; refresh before retrying",
    );
  return {
    write: await flushWrite(message.account),
    badgeRefreshed: await refreshBadge(),
  };
}

export async function trashMail(
  message: Mail,
): Promise<{ write: WriteStatus; badgeRefreshed: boolean }> {
  if (message.mailbox !== "inbox")
    throw new Error("Only inbox messages can be moved to Trash");
  if (message.account.backends.length === 0)
    throw new Error(
      "Himalaya did not identify this account's backend; patched account discovery is required",
    );
  // `message delete` can purge messages already in Trash; move never permanently deletes.
  const report = moveSchema.safeParse(
    await json([
      "--account",
      message.account.name,
      "message",
      "move",
      "--from",
      "inbox",
      "--to",
      "trash",
      "--",
      message.id,
    ]),
  );
  if (!report.success)
    throw new Error(
      "Move response did not confirm one processed message; refresh before retrying",
    );
  return {
    write: await flushWrite(message.account),
    badgeRefreshed: await refreshBadge(),
  };
}

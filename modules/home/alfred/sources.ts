// Alfred's sources, which house-agents reads on its own every few minutes
// (`config.sources`), inlined into house-agents.config.ts. The calendar wakes
// Alfred: at 7:00 with the day's plan and at the start and end of every timed
// entry. Unread mail, Slack messages, others' WhatsApp messages, T3 sessions
// that ended or wait for the owner, and others' changes in Anytype that
// arrive after a source's first read come into the conversation as notes,
// without waking him; what was
// already there is never noted, so neither a deploy nor reading the newest
// ones brings up a backlog.

const TIME_ZONE = "Europe/Warsaw";
const DAY_PLAN_AT = "07:00";
// Ids already noted, per source; the oldest are dropped past this many.
const SEEN = 500;

type Read = {
	call: (server: string, tool: string, args: Record<string, unknown>) => Promise<string>;
	cursor: unknown;
	now: number;
};
type Wake = { key: string; at: number; prompt: string };
type Update = { cursor: unknown; notes?: string[]; wakes?: Wake[] };

const wallParts = (time: number) =>
	Object.fromEntries(
		new Intl.DateTimeFormat("en-US", {
			timeZone: TIME_ZONE,
			hourCycle: "h23",
			year: "numeric",
			month: "2-digit",
			day: "2-digit",
			hour: "2-digit",
			minute: "2-digit",
			second: "2-digit",
		})
			.formatToParts(new Date(time))
			.map((part) => [part.type, part.value]),
	) as Record<string, string>;
const dayOf = (time: number) => {
	const p = wallParts(time);
	return `${p.year}-${p.month}-${p.day}`;
};
const hourOf = (time: number) => {
	const p = wallParts(time);
	return `${p.hour}:${p.minute}`;
};
// The moment of a wall-clock "YYYY-MM-DD HH:MM" in TIME_ZONE.
const fromWall = (day: string, hour: string) => {
	const utc = Date.parse(`${day}T${hour}:00Z`);
	const offset = (time: number) => {
		const p = wallParts(time);
		return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - Math.floor(time / 1000) * 1000;
	};
	return utc - offset(utc - offset(utc));
};
const nextDay = (day: string) => dayOf(fromWall(day, "12:00") + 24 * 3600 * 1000);

type Seen = { since: number; seen: string[] };
const seenOf = (cursor: unknown): Seen | undefined => {
	const c = cursor as Partial<Seen> | null;
	return typeof c?.since === "number" && Array.isArray(c.seen) ? (c as Seen) : undefined;
};
// Items that arrived since the first read and are not noted yet, and the cursor to keep.
const fresh = (seen: Seen, items: { id: string; at: number }[]) => {
	const noted = new Set(seen.seen);
	const added = items.filter((item) => item.at >= seen.since && !noted.has(item.id)).map((item) => item.id);
	return { added, cursor: { since: seen.since, seen: [...seen.seen, ...added].slice(-SEEN) } };
};
const clip = (text: string, length: number) => {
	const flat = String(text ?? "").replace(/\s+/g, " ").trim();
	return flat.length > length ? `${flat.slice(0, length)}…` : flat;
};

type Entry = { title: string; start: string; end: string };
// `get_events` lists one entry a line: - "Title" (Starts: <ISO>[ ...], Ends: <ISO>[ ...]) ...
const TIME = String.raw`\d{4}-\d{2}-\d{2}(?:T[\d:]+(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?`;
const ENTRY = new RegExp(String.raw`^- "(.+?)" \(Starts: (${TIME})[^,]*, Ends: (${TIME})`, "gm");
const isTimed = (time: string) => time.includes("T");
const entryLine = (entry: Entry) =>
	isTimed(entry.start)
		? `${hourOf(Date.parse(entry.start))}–${hourOf(Date.parse(entry.end))} „${entry.title}”`
		: `cały dzień: „${entry.title}”`;
const onDay = (entry: Entry, day: string) =>
	isTimed(entry.start) ? dayOf(Date.parse(entry.start)) === day : entry.start <= day && day < entry.end;

const calendar = async ({ call, now }: Read): Promise<Update> => {
	const today = dayOf(now);
	const tomorrow = nextDay(today);
	const text = await call("google", "get_events", {
		time_min: new Date(fromWall(today, "00:00")).toISOString(),
		time_max: new Date(fromWall(nextDay(tomorrow), "00:00")).toISOString(),
		max_results: 100,
	});
	const entries: Entry[] = [...text.matchAll(ENTRY)].map(([, title, start, end]) => ({ title, start, end }));
	// A changed format would otherwise cancel every wake-up of the calendar.
	if (entries.length === 0 && /^- "/m.test(text)) throw new Error("get_events: unknown entry format");
	const wakes: Wake[] = [today, tomorrow].map((day) => ({
		key: `day:${day}`,
		at: fromWall(day, DAY_PLAN_AT),
		prompt: `Nowy dzień. Kalendarz na dziś:\n${entries.filter((e) => onDay(e, day)).map((e) => `- ${entryLine(e)}`).join("\n") || "(pusty)"}`,
	}));
	for (const entry of entries.filter((e) => isTimed(e.start))) {
		const key = `${entry.start}|${entry.title}`;
		wakes.push(
			{ key: `start:${key}`, at: Date.parse(entry.start), prompt: `Kalendarz: zaczyna się ${entryLine(entry)}.` },
			{ key: `end:${key}`, at: Date.parse(entry.end), prompt: `Kalendarz: kończy się ${entryLine(entry)}.` },
		);
	}
	return { cursor: null, wakes };
};

const gmail = async ({ call, cursor, now }: Read): Promise<Update> => {
	const seen = seenOf(cursor);
	if (!seen) return { cursor: { since: now, seen: [] } };
	const found = await call("google", "search_gmail_messages", {
		query: `in:inbox is:unread after:${Math.floor(seen.since / 1000)}`,
		page_size: 25,
	});
	const ids = [...found.matchAll(/Message ID: (\S+)/g)].map(([, id]) => id);
	const { added, cursor: next } = fresh(seen, ids.map((id) => ({ id, at: seen.since })));
	if (added.length === 0) return { cursor: next };
	const text = await call("google", "get_gmail_messages_content_batch", { message_ids: added, format: "metadata" });
	const lines = text.split(/\n(?=Message ID: )/).flatMap((block) => {
		const field = (name: string) => new RegExp(`^${name}: (.*)$`, "m").exec(block)?.[1] ?? "";
		const id = field("Message ID");
		return id ? [`- od ${clip(field("From"), 80)}: ${clip(field("Subject"), 160)} (id ${id})`] : [];
	});
	return { cursor: next, notes: lines.length ? [`Nowe nieprzeczytane maile w Gmailu:\n${lines.join("\n")}`] : [] };
};

const proton = async ({ call, cursor, now }: Read): Promise<Update> => {
	const seen = seenOf(cursor);
	if (!seen) return { cursor: { since: now, seen: [] } };
	const accounts = JSON.parse(await call("proton", "list_available_accounts", {}));
	const account = (Array.isArray(accounts) ? accounts[0] : accounts)?.account_name;
	if (!account) return { cursor };
	const { emails = [] } = JSON.parse(
		await call("proton", "list_emails_metadata", { account_name: account, mailbox: "INBOX", seen: false, page_size: 25 }),
	) as { emails?: { email_id: string; subject?: string; sender?: string; date?: string }[] };
	const { added, cursor: next } = fresh(
		seen,
		emails.map((email) => ({ id: String(email.email_id), at: Date.parse(email.date ?? "") || 0 })),
	);
	const lines = emails
		.filter((email) => added.includes(String(email.email_id)))
		.map((email) => `- od ${clip(email.sender ?? "", 80)}: ${clip(email.subject ?? "", 160)} (id ${email.email_id})`);
	return { cursor: next, notes: lines.length ? [`Nowe nieprzeczytane maile w Proton Mailu:\n${lines.join("\n")}`] : [] };
};

type SlackMessage = { channel_id: string; ts: string; user_id?: string | null; text?: string; permalink?: string; subtype?: string | null };
// Messages people wrote; joins, topic changes and the like are left out.
const WRITTEN = new Set([undefined, null, "thread_broadcast", "file_share"]);
// The local archive lists names in pages; at most this many are read.
const NAME_PAGES = 20;

// Names of `ids` from a listing tool of the archive, page by page.
const slackNames = async (
	call: Read["call"],
	tool: string,
	args: Record<string, unknown>,
	ids: Set<string>,
	name: (item: Record<string, string | null>) => string | undefined,
) => {
	const names = new Map<string, string>();
	let cursor: string | undefined;
	for (let page = 0; page < NAME_PAGES && [...ids].some((id) => !names.has(id)); page++) {
		const { items = [], next_cursor } = JSON.parse(await call("slack", tool, { ...args, limit: 100, ...(cursor && { cursor }) })) as {
			items?: Record<string, string | null>[];
			next_cursor?: string | null;
		};
		for (const item of items) {
			const found = item.id && ids.has(item.id) ? name(item) : undefined;
			if (found) names.set(item.id as string, found);
		}
		if (!next_cursor) break;
		cursor = next_cursor;
	}
	return names;
};

const slack = async ({ call, cursor, now }: Read): Promise<Update> => {
	const seen = seenOf(cursor);
	if (!seen) return { cursor: { since: now, seen: [] } };
	const { items = [] } = JSON.parse(await call("slack", "unread", { limit: 50, max_text: 300 })) as { items?: SlackMessage[] };
	const messages = items.filter((item) => WRITTEN.has(item.subtype) && item.text?.trim());
	const { added, cursor: next } = fresh(
		seen,
		messages.map((m) => ({ id: `${m.channel_id}:${m.ts}`, at: Number(m.ts) * 1000 })),
	);
	if (added.length === 0) return { cursor: next };
	const fresher = messages.filter((m) => added.includes(`${m.channel_id}:${m.ts}`));
	const channels = await slackNames(call, "list_conversations", { include_archived: true }, new Set(fresher.map((m) => m.channel_id)), (c) =>
		c.kind === "im" ? `DM${c.user_id ? `:${c.user_id}` : ""}` : c.name ? `#${c.name}` : undefined,
	);
	const people = new Set(fresher.flatMap((m) => [m.user_id ?? "", (channels.get(m.channel_id) ?? "").replace(/^DM:/, "")]).filter((id) => /^[UW]/.test(id)));
	const users = await slackNames(call, "users", {}, people, (u) => u.real_name || u.name || undefined);
	const channelName = (id: string) => {
		const name = channels.get(id) ?? id;
		return name.startsWith("DM:") ? `DM z ${users.get(name.slice(3)) ?? name.slice(3)}` : name;
	};
	const lines = fresher.map(
		(m) => `- ${channelName(m.channel_id)} · ${users.get(m.user_id ?? "") ?? m.user_id ?? "?"}: ${clip(m.text ?? "", 300)}${m.permalink ? ` (${m.permalink})` : ""}`,
	);
	return { cursor: next, notes: [`Nowe nieprzeczytane wiadomości na Slacku:\n${lines.join("\n")}`] };
};

type WhatsAppChat = { jid: string; name?: string; is_group?: boolean; last_message_at?: string };
type WhatsAppMessage = { id: string; kind?: string; sender?: string; text?: string; time: string };
// Chats read per poll, the most recently active first.
const WHATSAPP_CHATS = 30;

const whatsapp = async ({ call, cursor, now }: Read): Promise<Update> => {
	const seen = seenOf(cursor);
	if (!seen) return { cursor: { since: now, seen: [], last: now } };
	const last = (cursor as { last?: number }).last ?? seen.since;
	// A minute back, so a message stored late is not missed; seen ids are noted once.
	const after = new Date(last - 60_000).toISOString();
	const { chats = [] } = JSON.parse(await call("whatsapp", "list_chats", { limit: WHATSAPP_CHATS })) as { chats?: WhatsAppChat[] };
	const items: { chat: WhatsAppChat; message: WhatsAppMessage }[] = [];
	for (const chat of chats.filter((c) => Date.parse(c.last_message_at ?? "") >= Date.parse(after))) {
		const read = async (args: Record<string, unknown>) =>
			(JSON.parse(await call("whatsapp", "list_messages", { chat: chat.jid, after, limit: 50, ...args })) as { messages?: WhatsAppMessage[] }).messages ?? [];
		// The owner's own messages are no news to him.
		const own = new Set((await read({ sender: "me" })).map((m) => m.id));
		for (const message of await read({})) if (!own.has(message.id)) items.push({ chat, message });
	}
	const { added, cursor: next } = fresh(seen, items.map(({ message }) => ({ id: message.id, at: Date.parse(message.time) })));
	const lines = items
		.filter(({ message }) => added.includes(message.id))
		.map(({ chat, message }) => {
			const where = chat.is_group ? `grupa „${chat.name ?? chat.jid}”` : (chat.name ?? chat.jid);
			const what = message.kind && message.kind !== "text" ? `[${message.kind}] ${clip(message.text ?? "", 200)}` : clip(message.text ?? "", 300);
			return `- ${where} · ${message.sender ?? "?"}: ${what}`;
		});
	return {
		cursor: { ...next, last: Math.max(last, ...items.map(({ message }) => Date.parse(message.time)).filter(Number.isFinite)) },
		notes: lines.length ? [`Nowe wiadomości na WhatsAppie:\n${lines.join("\n")}`] : [],
	};
};

type T3Thread = {
	threadId: string;
	title?: string;
	status: string;
	latestRunId?: string | null;
	updatedAt?: string;
	pullRequests?: { url: string; state?: string }[];
};
// A run that ended, or waits for the owner, is news; one still running is not yet.
const T3_STATUS: Record<string, string> = {
	completed: "skończona",
	failed: "nieudana",
	interrupted: "przerwana",
	cancelled: "anulowana",
	waiting: "czeka na odpowiedź",
};

// Threads of zilean's T3 whose latest run ended or waits since the last read;
// those the owner settled or snoozed are his already.
const t3 = async ({ call, cursor, now }: Read): Promise<Update> => {
	const { threads = [] } = JSON.parse(
		await call("t3", "t3_thread_list", {
			allProjects: true,
			limit: 30,
			settled: false,
			snoozed: false,
			statuses: Object.keys(T3_STATUS),
		}),
	) as { threads?: T3Thread[] };
	const runs = threads.map((thread) => ({
		thread,
		id: `${thread.threadId}:${thread.latestRunId ?? ""}:${thread.status}`,
		at: Date.parse(thread.updatedAt ?? "") || now,
	}));
	const seen = seenOf(cursor);
	// What is listed at first is no news.
	if (!seen) return { cursor: { since: now, seen: runs.map((run) => run.id).slice(-SEEN) } };
	const { added, cursor: next } = fresh(seen, runs);
	const lines = runs
		.filter((run) => added.includes(run.id))
		.map(({ thread }) => {
			const open = (thread.pullRequests ?? []).filter((pr) => pr.state === "open").map((pr) => pr.url);
			return `- „${clip(thread.title ?? "", 120)}”: ${T3_STATUS[thread.status] ?? thread.status} (wątek ${thread.threadId}${open.length ? `, otwarte PR: ${open.join(", ")}` : ""})`;
		});
	return { cursor: next, notes: lines.length ? [`Sesje T3:\n${lines.join("\n")}`] : [] };
};

type AnytypeObject = { id: string; name?: string; type?: string; properties?: { last_modified_by?: string; last_modified_date?: string } };

// Objects others changed in the shared Anytype space; the space's own member is
// the account Alfred (and the owner's tools) write as.
const anytype = async ({ call, cursor, now }: Read): Promise<Update> => {
	const seen = seenOf(cursor);
	if (!seen) return { cursor: { since: now, seen: [] } };
	const me = (JSON.parse(await call("anytype", "API-get-member-me", {})) as { identity?: string }).identity;
	if (!me) throw new Error("API-get-member-me: no identity");
	const { data = [] } = JSON.parse(
		// Alfred's own writes come in bursts and must not hide others' changes.
		await call("anytype", "API-search-space", {
			limit: 100,
			sorts: [{ property: "last_modified_date", direction: "desc" }],
			fields: ["name", "last_modified_date", "last_modified_by"],
		}),
	) as { data?: AnytypeObject[] };
	const changes = data
		.filter((object) => !String(object.properties?.last_modified_by ?? "").includes(me))
		.map((object) => ({
			object,
			id: `${object.id}:${object.properties?.last_modified_date ?? ""}`,
			at: Date.parse(object.properties?.last_modified_date ?? "") || 0,
		}));
	const { added, cursor: next } = fresh(seen, changes);
	if (added.length === 0) return { cursor: next };
	const { data: members = [] } = JSON.parse(await call("anytype", "API-list-members", {})) as {
		data?: { name?: string; identity?: string }[];
	};
	const who = (by: string) => members.find((member) => member.identity && by.includes(member.identity))?.name ?? "ktoś";
	const lines = changes
		.filter((change) => added.includes(change.id))
		.map(
			({ object }) =>
				`- ${who(object.properties?.last_modified_by ?? "")}: ${object.type ?? "obiekt"} „${clip(object.name ?? "", 120)}” (id ${object.id})`,
		);
	return { cursor: next, notes: [`Zmiany innych osób w Anytype:\n${lines.join("\n")}`] };
};

const sources = {
	kalendarz: { everyMinutes: 5, poll: calendar },
	gmail: { everyMinutes: 5, poll: gmail },
	proton: { everyMinutes: 5, poll: proton },
	slack: { everyMinutes: 5, poll: slack },
	whatsapp: { everyMinutes: 5, poll: whatsapp },
	t3: { everyMinutes: 5, poll: t3 },
	anytype: { everyMinutes: 10, poll: anytype },
};

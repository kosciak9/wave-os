import {
  Action,
  ActionPanel,
  Detail,
  Icon,
  Keyboard,
  List,
  Toast,
  showToast,
  useNavigation,
} from "@vicinae/api";
import { useEffect, useRef, useState } from "react";
import {
  AccountInbox,
  Account,
  Mail,
  WriteStatus,
  archiveMail,
  confirmWrite,
  errorText,
  escapeMarkup,
  isSeen,
  listAccounts,
  loadInbox,
  readMail,
  sender,
} from "./mail";

const archiveShortcut: Keyboard.Shortcut = { modifiers: ["ctrl"], key: "e" };

type InboxState =
  | { status: "loading" }
  | { status: "failed"; error: string }
  | { status: "ready"; accounts: AccountState[] };

type AccountState =
  | { status: "loading"; account: Account }
  | { status: "loaded"; inbox: AccountInbox };

function MessageDetail({
  message,
  body,
  notice,
  confirmation,
  archive,
}: {
  message: Mail;
  body: string;
  notice: string;
  confirmation: Promise<string>;
  archive: (message: Mail) => Promise<void>;
}) {
  const { pop } = useNavigation();
  const [busy, setBusy] = useState(true);
  const [status, setStatus] = useState(notice);
  useEffect(() => {
    let active = true;
    void confirmation.then((value) => {
      if (active) {
        setStatus(value);
        setBusy(false);
      }
    });
    return () => {
      active = false;
    };
  }, [confirmation]);
  return (
    <Detail
      navigationTitle={escapeMarkup(message.subject || "No subject")}
      markdown={body}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label
            title="Account"
            text={escapeMarkup(message.account.name)}
          />
          <Detail.Metadata.Label
            title="From"
            text={escapeMarkup(sender(message))}
          />
          {message.date && (
            <Detail.Metadata.Label
              title="Date"
              text={new Date(message.date).toLocaleString()}
            />
          )}
          {status && (
            <Detail.Metadata.Label title="Status" text={escapeMarkup(status)} />
          )}
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <Action
            title={busy ? "Waiting for mail operation…" : "Archive"}
            icon={Icon.Box}
            shortcut={archiveShortcut}
            onAction={async () => {
              if (busy) return;
              setBusy(true);
              await archive(message);
              setBusy(false);
            }}
          />
          <Action title="Back to Inbox" icon={Icon.ArrowLeft} onAction={pop} />
        </ActionPanel>
      }
    />
  );
}

export default function Inbox() {
  const [state, setState] = useState<InboxState>({ status: "loading" });
  const [accountFilter, setAccountFilter] = useState("");
  const [search, setSearch] = useState("");
  const [busy, setBusy] = useState(false);
  const [writeNotices, setWriteNotices] = useState<Record<string, string>>({});
  const [selectedId, setSelectedId] = useState("");
  const [advanceAfterArchive, setAdvanceAfterArchive] = useState(false);
  const inFlight = useRef(false);
  const generation = useRef(0);
  const { push, pop } = useNavigation();

  async function reload() {
    if (inFlight.current) return;
    const request = ++generation.current;
    setState({ status: "loading" });
    try {
      const accounts = await listAccounts();
      if (request !== generation.current) return;
      setState({
        status: "ready",
        accounts: accounts.map((account) => ({ status: "loading", account })),
      });
      await Promise.all(
        accounts.map(async (account) => {
          const inbox = await loadInbox(account);
          const write = account.backends.includes("pimdir")
            ? await confirmWrite(account)
            : null;
          if (request !== generation.current) return;
          setWriteNotices((current) => {
            const next = { ...current };
            if (write?.status === "remote") delete next[account.name];
            else if (write?.status === "pending")
              next[account.name] = write.message;
            return next;
          });
          setState((current) =>
            current.status !== "ready" || request !== generation.current
              ? current
              : {
                  ...current,
                  accounts: current.accounts.map((entry) =>
                    entry.status === "loading" &&
                    entry.account.name === account.name
                      ? { status: "loaded", inbox }
                      : entry,
                  ),
                },
          );
        }),
      );
    } catch (error) {
      if (request === generation.current)
        setState({ status: "failed", error: errorText(error) });
    }
  }

  // The CLI has no subscription API; discover and fetch metadata on command mount.
  useEffect(() => {
    void reload();
    return () => {
      generation.current++;
    };
  }, []);

  async function mutationNotice(
    account: string,
    write: WriteStatus,
    badgeRefreshed: boolean,
    successTitle: string,
  ): Promise<string> {
    const notice = [
      write.status === "pending" ? write.message : "",
      badgeRefreshed
        ? ""
        : "Mail badge refresh unavailable; the mail operation was not undone.",
    ]
      .filter(Boolean)
      .join(" ");
    setWriteNotices((current) => {
      const next = { ...current };
      if (write.status === "pending") next[account] = write.message;
      else delete next[account];
      return next;
    });
    await showToast({
      style:
        write.status === "pending" ? Toast.Style.Failure : Toast.Style.Success,
      title:
        write.status === "pending"
          ? "Local change; remote status unconfirmed"
          : successTitle,
      message: notice || undefined,
    });
    return notice;
  }

  async function archive(message: Mail): Promise<boolean> {
    if (inFlight.current) return false;
    inFlight.current = true;
    setBusy(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Archiving…",
    });
    try {
      const result = await archiveMail(message);
      setState((current) =>
        current.status !== "ready"
          ? current
          : {
              ...current,
              accounts: current.accounts.map((entry) =>
                entry.status === "loading"
                  ? entry
                  : {
                      ...entry,
                      inbox: {
                        ...entry.inbox,
                        messages: entry.inbox.messages.filter(
                          (item) => item.key !== message.key,
                        ),
                      },
                    },
              ),
            },
      );
      await toast.hide();
      await mutationNotice(
        message.account.name,
        result.write,
        result.badgeRefreshed,
        "Archived",
      );
      return true;
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Archive not confirmed";
      toast.message = errorText(error);
      return false;
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  }

  async function open(message: Mail) {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Reading…",
    });
    try {
      const result = await readMail(message);
      await toast.hide();
      if (result.seenLocally && !isSeen(message)) {
        setState((current) =>
          current.status !== "ready"
            ? current
            : {
                ...current,
                accounts: current.accounts.map((entry) =>
                  entry.status === "loading"
                    ? entry
                    : {
                        ...entry,
                        inbox: {
                          ...entry.inbox,
                          messages: entry.inbox.messages.map((item) =>
                            item.key === message.key
                              ? {
                                  ...item,
                                  flags: [
                                    ...item.flags,
                                    { raw: "\\Seen", iana: "seen" },
                                  ],
                                }
                              : item,
                          ),
                        },
                      },
                ),
              },
        );
      }
      const confirmation = result.confirmation
        .then(async ({ write, badgeRefreshed }) => {
          if (write)
            return mutationNotice(
              message.account.name,
              write,
              badgeRefreshed,
              "Opened and marked seen",
            );
          return [
            writeNotices[message.account.name] ?? "",
            badgeRefreshed ? "" : "Mail badge refresh unavailable.",
          ]
            .filter(Boolean)
            .join(" ");
        })
        .catch(() => "Message opened; status confirmation unavailable.");
      push(
        <MessageDetail
          message={message}
          body={result.body}
          notice={
            isSeen(message)
              ? ""
              : "Message opened; confirming Seen and sync status…"
          }
          confirmation={confirmation}
          archive={async (current) => {
            if (await archive(current)) {
              pop();
              setAdvanceAfterArchive(true);
            }
          }}
        />,
      );
      await confirmation;
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Read not completed";
      toast.message = errorText(error);
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  }

  const accountStates = state.status === "ready" ? state.accounts : [];
  const inboxes = accountStates.flatMap((entry) =>
    entry.status === "loaded" ? [entry.inbox] : [],
  );
  const loadingAccounts = accountStates.flatMap((entry) =>
    entry.status === "loading" ? [entry.account] : [],
  );
  const accounts = accountStates.map((entry) =>
    entry.status === "loaded" ? entry.inbox.account : entry.account,
  );
  const allMessages = inboxes.flatMap((inbox) => inbox.messages);
  const messages = allMessages
    .filter(
      (message) => !accountFilter || message.account.name === accountFilter,
    )
    .sort(
      (left, right) =>
        (Date.parse(right.date ?? "") || 0) -
        (Date.parse(left.date ?? "") || 0),
    );
  const errors = inboxes.filter((inbox) => inbox.error !== null);
  // Native selection provides the next visible fuzzy-ranked item; do not duplicate its filtering.
  useEffect(() => {
    if (!advanceAfterArchive) return;
    if (
      messages.length === 0 ||
      selectedId.startsWith("error:") ||
      selectedId.startsWith("pending:") ||
      selectedId.startsWith("loading:")
    ) {
      setAdvanceAfterArchive(false);
      return;
    }
    const next = messages.find((message) => message.key === selectedId);
    if (!next || inFlight.current) return;
    setAdvanceAfterArchive(false);
    void open(next);
  }, [advanceAfterArchive, selectedId, state]);
  const writeNotice = Object.entries(writeNotices)
    .map(([account, notice]) => `${account}: ${notice}`)
    .join(" ");
  const inboxZero =
    state.status === "ready" &&
    inboxes.length > 0 &&
    loadingAccounts.length === 0 &&
    errors.length === 0 &&
    allMessages.length === 0 &&
    !search.trim() &&
    !accountFilter &&
    !writeNotice;
  const refreshAction = (
    <Action
      title="Refresh Inbox"
      icon={Icon.ArrowClockwise}
      shortcut="refresh"
      onAction={reload}
    />
  );

  return (
    <List
      filtering
      isLoading={
        state.status === "loading" || loadingAccounts.length > 0 || busy
      }
      searchBarPlaceholder="Search all inbox subjects and senders…"
      onSearchTextChange={(value) => {
        setSearch(value);
        setAdvanceAfterArchive(false);
      }}
      onSelectionChange={setSelectedId}
      navigationTitle={
        writeNotice
          ? "Inbox · remote changes unconfirmed"
          : errors.length
            ? "Inbox · some accounts unavailable"
            : "Inbox"
      }
      actions={<ActionPanel>{refreshAction}</ActionPanel>}
      searchBarAccessory={
        <List.Dropdown
          tooltip="Account"
          value={accountFilter}
          onChange={(value) => {
            setAccountFilter(value);
            setAdvanceAfterArchive(false);
          }}
          storeValue={false}
        >
          <List.Dropdown.Item title="All Accounts" value="" />
          {accounts.map((account) => (
            <List.Dropdown.Item
              key={account.name}
              title={escapeMarkup(account.name)}
              value={account.name}
            />
          ))}
        </List.Dropdown>
      }
    >
      <List.EmptyView
        icon={inboxZero ? Icon.CheckCircle : Icon.Envelope}
        title={
          inboxZero
            ? "Inbox zero"
            : state.status === "loading" || loadingAccounts.length > 0
              ? "Loading inboxes…"
              : state.status === "failed"
                ? "Unable to load accounts"
                : errors.length
                  ? "Inbox is incomplete"
                  : accounts.length === 0
                    ? "No accounts configured"
                    : "No matching messages"
        }
        description={
          state.status === "failed"
            ? state.error
            : escapeMarkup(writeNotice) ||
              (errors.length
                ? "Some accounts could not be loaded; refresh to retry."
                : "")
        }
      />
      {messages.map((message) => (
        <List.Item
          key={message.key}
          id={message.key}
          title={escapeMarkup(message.subject || "No subject")}
          subtitle={escapeMarkup(sender(message))}
          icon={isSeen(message) ? Icon.Check : Icon.Envelope}
          keywords={[
            message.subject,
            ...message.from.flatMap((address) => [
              address.email,
              address.name ?? "",
            ]),
          ]}
          accessories={[
            { tag: escapeMarkup(message.account.name) },
            {
              text: message.date ? new Date(message.date).toLocaleString() : "",
            },
          ]}
          actions={
            <ActionPanel>
              <Action
                title="Read"
                icon={Icon.Envelope}
                onAction={() => open(message)}
              />
              <Action
                title="Archive"
                icon={Icon.Box}
                shortcut={archiveShortcut}
                onAction={() => archive(message)}
              />
              {refreshAction}
            </ActionPanel>
          }
        />
      ))}
      {loadingAccounts.length > 0 && (
        <List.Section title="Loading accounts">
          {loadingAccounts.map((account) => (
            <List.Item
              key={`loading:${account.name}`}
              id={`loading:${account.name}`}
              title={escapeMarkup(account.name)}
              subtitle="Loading inbox…"
              icon={Icon.ArrowClockwise}
              actions={<ActionPanel>{refreshAction}</ActionPanel>}
            />
          ))}
        </List.Section>
      )}
      {errors.length > 0 && (
        <List.Section title="Accounts needing attention">
          {errors.map((inbox) => (
            <List.Item
              key={`error:${inbox.account.name}`}
              id={`error:${inbox.account.name}`}
              title={escapeMarkup(
                `${inbox.account.name}: inbox could not be fully loaded`,
              )}
              subtitle={inbox.error ?? ""}
              icon={Icon.Exclamationmark}
              actions={<ActionPanel>{refreshAction}</ActionPanel>}
            />
          ))}
        </List.Section>
      )}
      {Object.keys(writeNotices).length > 0 && (
        <List.Section title="Remote changes unconfirmed">
          {Object.entries(writeNotices).map(([account, notice]) => (
            <List.Item
              key={`pending:${account}`}
              id={`pending:${account}`}
              title={escapeMarkup(account)}
              subtitle={escapeMarkup(notice)}
              icon={Icon.Exclamationmark}
              actions={<ActionPanel>{refreshAction}</ActionPanel>}
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}

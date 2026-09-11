# OpenClaw operator notes

This is the runbook for the fresh OpenClaw deployment. It is intentionally
small: the module describes the local service and its runtime wiring; it does
not own credentials, provider accounts, or durable backup infrastructure.

## Ownership boundaries

- **This deployment owns:** the OpenClaw configuration, local runtime wiring,
  the host-native read-only `mac-apps` MCP server, Podman machine/image helpers,
  and the one-time seed helper.
- **The operator owns:** Secret Store entries, OAuth consent and refresh-token
  lifecycle, Telegram pairing, Tailscale access policy, theme selection, Full
  Disk Access consent, and checking the Control UI visually.
- **Upstream owns:** OpenClaw behavior and the pinned 2026.9.3 CLI/image
  inputs. A temporary fork is used until the upstream change is available.

Never put a token, password, private key, or OAuth code in this file, shell
history, Nix expressions, or a command line. Use the Secret Store and its
prompt/standard-input mechanisms instead.

## Before activation

Activation is **prohibited unless the user explicitly requests it**. These
steps only prepare inputs; do not run `home-manager switch`,
`darwin-rebuild switch`, or `nixos-rebuild switch` as part of this runbook.

1. Confirm that the deployment's temporary fork and pinned 2026.9.3 inputs are
   the intended revisions.
2. Build or use the pinned 2026.9.3 CLI. The first explicitly authorized
   activation installs `openclaw-bootstrap`; run it immediately afterward as
   the explicit host-side credential preparation command:

   ```sh
   openclaw-bootstrap
   ```

    `openclaw-bootstrap` is idempotent: preservation requires exactly one
    `kind=secret` entry for each required secret. The Gateway token must have
    `allowedHosts=[]`; Telegram must have
    `allowedHosts=["api.telegram.org"]`. Any duplicate or unexpected kind/host
    metadata fails closed and requires intentional operator correction. A
    missing Telegram entry requires the command to have an interactive terminal
    so the pinned CLI can use its masked prompt. The command prints only Secret
    Store metadata and audit output, never secret values, and does not inspect
    backing state. Until both secrets exist, the Gateway may fail or retry
    closed.

## Podman helpers

Run these explicit helpers only when the relevant runtime operation is wanted.
They are safe to repeat. The exact machine and image are fixed; do not replace
them with credentials or ad-hoc tags.

```sh
openclaw-sandbox-bootstrap
# Run this only when the already-created machine is not running.
podman machine start openclaw-sandbox
openclaw-sandbox-image-build
```

Login launchd starts the already-created `openclaw-sandbox` machine at login,
but has no KeepAlive. A normal reboot therefore does not require a manual start
unless the one-shot job fails or the VM later stops. The Gateway remains
loopback-only and is exposed through the existing Caddy daemon at
`https://renekton.dusky-diatonic.ts.net:18790`. Caddy obtains the certificate
through Tailscale, so this ingress depends on the system Caddy/Tailscale
certificate integration. The shared Gateway token is mandatory; Caddy ingress
does not provide Tailscale identity authentication.

Mobile setup codes advertise the Caddy/Tailscale WSS URL
`wss://renekton.dusky-diatonic.ts.net:18790`. Treat setup codes like passwords;
they expire after 10 minutes and are single-use.

OpenCode remains on `https://renekton.dusky-diatonic.ts.net` (port 443). OpenClaw
is intentionally separate on port 18790 and does not use managed Tailscale
Serve. A future Tailscale Service is an option only after deliberate tagged
device and administrator approval work; do not make that control-plane change
as part of this deployment.

Workspace seeding is a Home Manager activation helper. It copies only absent
files and does not overwrite operator changes; there is no separate manual
seed-marker command.

## After an explicitly requested activation

Perform this sequence, stopping if any step reports an error:

The one-shot app LaunchAgent may have timed out while explicit secret, Podman,
and image provisioning was underway. After Gateway readiness, the operator may
manually open `~/Applications/Home Manager Apps/OpenClaw.app` for pairing and visual checks.

1. Verify the service locally and confirm the expected image/tag.
2. Complete provider OAuth in the Control UI; approve only the requested
   scopes and let the Secret Store retain resulting credentials.
3. Pair Telegram using the displayed pairing flow; send a harmless test
   message only after confirming the recipient/chat.
4. Select and save the theme manually. Theme automation is intentionally not
   provided. Import `https://tweakcn.com/themes/cmttw7duz000104jm3plz7tvn` if
   using the approved theme.
5. Open `https://renekton.dusky-diatonic.ts.net:18790` and authenticate with
   the Gateway token. Confirm that Caddy can obtain the Tailscale-backed
   certificate before troubleshooting the Gateway.
6. Inspect the Control UI visually; accessibility/CLI checks do not replace
   this manual check.

The app agent opens `~/Applications/Home Manager Apps/OpenClaw.app`. Home
Manager's standard macOS app collector owns this location and installs the
corrected app bundle there.

## Sandbox boundary

The full sandbox shell and network access can modify and exfiltrate data within
the dedicated workspace and network boundary. It has no host-home,
`Developer`, or socket bind mounts.

Any future MCP addition requires exact `server__tool` IDs to be listed in both
the global policy and the sandbox policy; adding an MCP server alone is not
 sufficient.

The `mac-apps` server is the one intentional host-native exception to the
sandbox boundary. It runs from the pinned Nix executable and is restricted to
a read-only Mail and Calendar data surface with exactly 13 tools exposed to
OpenClaw. Notes, Reminders, Contacts, daily briefing, and generic resource
utility tools are unavailable. `mail_fts_index` may write the local derived FTS
cache and logs under `~/.macos-mcp`; it cannot write Mail or Calendar data.
Grant Full Disk Access to that pinned Nix Node executable and the OpenClaw
Gateway process (not merely to a terminal), then restart the Gateway after
changing consent. `MACOS_MCP_READONLY` prevents write registration against
those Apple data stores, so that configured data surface is guaranteed
read-only. Destructive confirmation and a one-operation-per-minute write limit
are defense-in-depth. `mail_move` and `mail_set_flags` are also excluded by the
OpenClaw tool filter, and all application-data writes are unavailable.

The server may create `~/.macos-mcp/mail-fts.db` and
`~/.macos-mcp/macos-mcp.log` (plus rotated log backups). This expected runtime
state can contain local mail-derived index/log data; do not copy it into Nix
configuration or backups without reviewing its sensitivity.

## Acceptance checks

Use read-only checks first. Every Podman acceptance command names the exact
`openclaw-sandbox` connection and expected image:

```sh
podman --connection openclaw-sandbox ps --filter 'name=openclaw' --format '{{.Names}}\t{{.Status}}'
podman --connection openclaw-sandbox image exists openclaw-sandbox:bookworm-slim
curl --fail --silent --show-error "${OPENCLAW_HEALTH_URL:-http://127.0.0.1:18789/healthz}" >/dev/null
curl --fail --silent --show-error "${OPENCLAW_STARTUP_URL:-http://127.0.0.1:18789/startupz}" >/dev/null
curl --fail --silent --show-error "${OPENCLAW_READY_URL:-http://127.0.0.1:18789/readyz}" >/dev/null
openclaw --version
/usr/bin/codesign --verify --deep --strict "$HOME/Applications/Home Manager Apps/OpenClaw.app"
```

Probe the OpenClaw-filtered MCP tool surface without invoking a write:

```sh
openclaw mcp probe mac-apps --json
```

The OpenClaw-filtered result must contain exactly these 13 names from the Nix
`macAppsMcpTools` list: `mail_list_accounts`, `mail_list_mailboxes`,
`mail_get_emails`, `mail_get_email`, `mail_search`, `mail_search_body`,
`mail_fts_index`, `mail_fts_stats`, `calendar_list`, `calendar_today`,
`calendar_this_week`, `calendar_get_events`, and `calendar_get_event`.
`mail_move` and `mail_set_flags` must be absent. Raw upstream READONLY mode
advertises 26 tools, including those two filtered mail mutation exceptions and
four Notes tools; do not use that raw `tools/list` response for this
acceptance check. The FTS database and log under `~/.macos-mcp` are expected
after startup/indexing. Adding another server still requires synchronizing its
exact `server__tool` IDs in both `tools.alsoAllow` and
`tools.sandbox.tools.allow`; configuring the server alone is insufficient.

Then confirm in the UI that OAuth is present, pairing is intentional, the
chosen theme persisted, and no disabled capability is advertised as enabled.

### Known static audit findings

For the final pinned v2026.9.3 isolated configuration, `openclaw security audit --json`
has these documented residuals:

- `tools.exec.security_full_configured` is intentional: execution is full only
  inside the dedicated Podman sandbox. The bridge-network and workspace
  exfiltration risk is documented above.
- `gateway.nodes.deny_commands_ineffective` remains for exactly these six real
  pinned desktop-host command constants: `system.execApprovals.get`,
  `system.execApprovals.set`, `fs.listDir`, `terminal.upload`,
  `mcp.tools.call.v1`, and `agent.cli.claude.run.v1`. They remain in the exact
  deny policy even though the auditor does not include them in its default
  command-name set. Browser/plugin tools and the desktop host are also
  disabled. Any additional node finding is a blocker.
- `fs.config.perms_world_readable` is a generic warning/critical for the
  immutable 0444 Nix-store config. That file contains SecretRef identifiers
  only, never credential values; secret values remain in the OpenClaw Secret
  Store. Any literal secret in Nix is a blocker.

The isolated summary is accepted as critical=1, warn=2, info=1 only when these
exact findings are present. Any change or new finding requires review.

## Locked compromises and unwind plan

| Locked compromise | Current consequence | Unwind when ready |
|---|---|---|
| Temporary fork | Upstream updates are not consumed automatically. | Move back to the upstream release after the required change lands; re-check config and OAuth. |
| Apt-built sandbox image | Image provenance/build time differs from the preferred artifact. | Replace with the approved pinned image and re-run read-only acceptance checks. |
| No KeepAlive Podman restart | Login launchd starts the existing machine once; recovery is needed only if that job fails or the VM later stops. | Add a reviewed restart policy only after operational approval. |
| Caddy-owned HTTPS ingress | The Gateway stays loopback-only; access depends on the existing Caddy daemon and its Tailscale certificate integration, with token authentication still required. | Consider a Tailscale Service only after deliberate tagged-device and administrator approval work; retain this route otherwise. |
| Seed-once helper | Home Manager activation copies only absent workspace files and never silently reconciles edits. | Make migrations explicit and preserve operator edits. |
| Manual theme | Theme changes require the operator in the UI. | Add supported, reviewed theme automation. |
| Telegram 20 MiB limit | Larger Telegram transfers are unavailable. | Use a supported larger-transfer path and retest limits. |
| No managed web-search fallback | Search is unavailable when the configured provider is unavailable. | Add an approved managed fallback with its own credentials/policy. |
| Audio is entitlement-dependent | Audio features may remain unavailable. | Enable only after the account entitlement is confirmed. |
| Canvas, file transfer, browser, Meme Maker, ClawHub, Node Connect, and Workshop disabled | Those capabilities are intentionally unavailable. | Enable each separately after security and acceptance review. |
| Message and cross-session sends disabled | Agents cannot send messages or cross-session traffic. | Re-enable only with explicit routing, consent, and abuse controls. |
| MCP bundle omitted | No bundled MCP servers are available. | Add an reviewed, least-privilege MCP bundle when approved. |
| Control UI visual verification manual | Automated acceptance cannot prove visual correctness. | Retain an operator screenshot/checklist or add a reviewed visual test. |
| No backup infrastructure in this change | Recovery depends on existing operator/platform backups. | Provision and test backups in a separate change. |

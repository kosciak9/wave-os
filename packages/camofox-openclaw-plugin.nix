{
  stdenvNoCC,
  jq,
  lib,
  camofox-browser-source,
  browser-decision,
}:

let
  # Import only the audited runtime modules, never fixtures, test data or benchmark scripts.
  executorRuntime = builtins.path {
    path = ./browser-executor;
    name = "browser-executor-runtime";
    filter =
      path: type:
      (type == "directory" && path == toString ./browser-executor)
      || (
        type == "regular"
        && builtins.elem (builtins.baseNameOf path) [
          "core.mjs"
          "bridge.mjs"
          "plugin.mjs"
          "camofox.mjs"
          "resolver.mjs"
          "observations.mjs"
          "state.mjs"
        ]
      );
  };
  inherit (camofox-browser-source) version;
  tools = {
    camofox_create_tab = "Open a Camoufox tab, optionally in a named login profile";
    camofox_snapshot = "Text-only accessibility snapshot with offset pagination";
    camofox_close_tab = "Close a Camoufox tab opened by this session";
    camofox_list_tabs = "List Camoufox tabs opened by this session";
    lightpanda_read = "Read a public JavaScript page as markdown with Lightpanda";
    browser_execute = "Start bounded local browser execution";
    browser_resolve = "Resolve a single-use browser execution handoff";
    browser_observations = "Read bounded value-free browser operation observations";
    browser_login_open = "Open a profile login page in the owner remote viewer";
    browser_login_save = "Persist an owner login in a browser profile";
  };
  toolsJson = builtins.toJSON (lib.attrNames tools);
  toolManifestJson = builtins.toJSON (
    lib.mapAttrsToList (name: description: { inherit name description; }) tools
  );
  configProperties = builtins.toJSON {
    viewerUrl = {
      type = "string";
      description = "HTTPS noVNC viewer URL the owner opens to log in";
    };
    lightpandaUrl = {
      type = "string";
      description = "Loopback Lightpanda MCP endpoint";
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "camofox-openclaw-plugin";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    jq --argjson tools '${toolManifestJson}' --arg version ${lib.escapeShellArg version} \
          ' .version = $version
          | .main = "plugin.js"
          | .files = [ "plugin.js", "openclaw.plugin.json" ]
          | .openclaw.extensions = [ "plugin.js" ]
          | .openclaw.runtimeExtensions = [ "plugin.js" ]
          | .openclaw.tools = $tools
          | del(.bin, .scripts, .dependencies, .optionalDependencies, .devDependencies,
              .peerDependencies, .peerDependenciesMeta, .overrides)' \
          '${camofox-browser-source}/package.json' > "$out/package.json"
    jq --argjson tools '${toolsJson}' --argjson properties '${configProperties}' \
          --arg version ${lib.escapeShellArg version} \
          '.version = $version | .tools = $tools | .contracts.tools = $tools
           | .configSchema.properties += $properties' \
          '${camofox-browser-source}/openclaw.plugin.json' > "$out/openclaw.plugin.json"
    cat > "$out/plugin.js" <<'EOF'
    import { createHash, createHmac, randomBytes } from "node:crypto";
    import { registerLocalBrowserExecutor, registerBrowserObservations } from "${executorRuntime}/plugin.mjs";
    import { createCamofoxBrowser } from "${executorRuntime}/camofox.mjs";
    import { createObservationStore } from "${executorRuntime}/observations.mjs";
    import { createTabState } from "${executorRuntime}/state.mjs";

    const stateDirectory = process.env.OPENCLAW_STATE_DIR
      ? `''${process.env.OPENCLAW_STATE_DIR}/browser-executor`
      : `''${process.env.HOME}/.openclaw/browser-executor`;
    const observations = createObservationStore(stateDirectory);
    const tabState = createTabState(stateDirectory);
    const inspectedIncidents = new Map();

    function backendUrl(api) {
      const url = new URL(api.pluginConfig?.url ?? "http://127.0.0.1:9377");
      if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || url.username || url.password ||
          url.pathname !== "/" || url.search || url.hash || !url.port)
        throw new Error("Camofox requires a local backend URL");
      return url.origin;
    }

    function lightpandaUrl(api) {
      const url = new URL(api.pluginConfig?.lightpandaUrl ?? "http://127.0.0.1:9378/mcp");
      if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || url.username || url.password ||
          url.pathname !== "/mcp" || url.search || url.hash || !url.port)
        throw new Error("Lightpanda requires a local MCP endpoint");
      return url.href;
    }

    async function readJson(response, maxBytes) {
      if (Number(response.headers.get("content-length")) > maxBytes) {
        await response.body?.cancel();
        throw new Error("response_too_large");
      }
      let text = "";
      let size = 0;
      const decoder = new TextDecoder();
      for await (const chunk of response.body) {
        size += chunk.byteLength;
        if (size > maxBytes) throw new Error("response_too_large");
        text += decoder.decode(chunk, {stream: true});
      }
      text += decoder.decode();
      return JSON.parse(text);
    }

    async function localRequest(api, path, { method, body, maxBytes = 250000 } = {}) {
      const key = process.env.CAMOFOX_ACCESS_KEY;
      if (!key) throw new Error("Camofox access key is required");
      try {
        const response = await fetch(new URL(path, backendUrl(api)), {
          method: method ?? (body ? "POST" : "GET"), redirect: "error",
          signal: AbortSignal.timeout(15000),
          headers: { Authorization: `Bearer ''${key}`, ...(body ? {"Content-Type": "application/json"} : {}) },
          ...(body ? {body: JSON.stringify(body)} : {}),
        });
        if (!response.ok) throw new Error("backend_unavailable");
        return await readJson(response, maxBytes);
      } catch {
        throw new Error("Camofox local request failed");
      }
    }

    const text = payload => ({ content: [{type: "text", text: JSON.stringify(payload)}] });
    const tabPath = params => {
      if (typeof params?.tabId !== "string" || !/^[\w-]{1,128}$/.test(params.tabId))
        throw new Error("Invalid tab ID");
      return encodeURIComponent(params.tabId);
    };
    const profilePattern = "^[a-z0-9][a-z0-9-]{0,39}$";

    function checkedUrl(value) {
      try {
        if (typeof value !== "string" || value.length > 2048) throw Error();
        const url = new URL(value);
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw Error();
        return url.href;
      } catch { throw new Error("Invalid tab URL"); }
    }

    // Alfred names profiles and remembers them; Camofox only sees a hash, and
    // its persistence plugin keeps one durable storage state per userId.
    function profileUserId(profile) {
      if (typeof profile !== "string" || !new RegExp(profilePattern).test(profile))
        throw new Error("Invalid browser profile");
      return createHash("sha256").update(`camofox-profile:''${profile}`).digest("hex");
    }

    // The raw factory context is the authority. A session binds to one profile,
    // or to its own throwaway namespace (""), on its first tab, so page content
    // seen later cannot switch it to another account.
    const sessionProfiles = new Map();
    function identity(ctx, requested) {
      const scope = [ctx?.sessionKey, ctx?.sessionId].find(
        (value) => typeof value === "string" && value.length > 0,
      );
      const accessKey = process.env.CAMOFOX_ACCESS_KEY;
      if (!scope || typeof accessKey !== "string" || accessKey.length === 0)
        throw new Error("Camofox plugin requires scoped identity and access key");
      const session = createHmac("sha256", accessKey).update(scope).digest("hex");
      let profile = sessionProfiles.get(scope);
      if (requested !== undefined) {
        if (requested !== "") profileUserId(requested);
        if (profile !== undefined && profile !== requested)
          throw new Error("Browser session is already bound to another profile");
        if (profile === undefined) {
          if (sessionProfiles.size >= 1024) sessionProfiles.delete(sessionProfiles.keys().next().value);
          sessionProfiles.set(scope, requested);
          profile = requested;
        }
      }
      return { userId: profile ? profileUserId(profile) : session, sessionKey: session, profile: profile || null };
    }

    async function lightpandaRead(api, params) {
      const url = checkedUrl(params?.url);
      const maxBytes = params?.maxBytes ?? 20000;
      if (!Number.isSafeInteger(maxBytes) || maxBytes < 1000 || maxBytes > 60000)
        throw new Error("Invalid maxBytes");
      const endpoint = lightpandaUrl(api);
      let session = null;
      let id = 0;
      // Each read gets its own MCP session, hence its own page and cookie jar.
      const rpc = async (method, args) => {
        const response = await fetch(endpoint, {
          method: "POST", redirect: "error", signal: AbortSignal.timeout(30000),
          headers: {"Content-Type": "application/json", Accept: "application/json",
            ...(session ? {"Mcp-Session-Id": session} : {})},
          body: JSON.stringify({jsonrpc: "2.0", id: ++id, method, params: args}),
        });
        if (!response.ok) throw new Error("backend_unavailable");
        session ??= response.headers.get("mcp-session-id");
        const reply = await readJson(response, maxBytes + 50000);
        if (reply?.error || !reply?.result) throw new Error("backend_rejected");
        return reply.result;
      };
      const call = async (name, args) => {
        const result = await rpc("tools/call", {name, arguments: args});
        const body = (result.content ?? []).filter(item => item?.type === "text").map(item => item.text).join("\n");
        return {result, body};
      };
      try {
        await rpc("initialize", {protocolVersion: "2025-06-18", capabilities: {},
          clientInfo: {name: "openclaw-browser", version: "1"}});
        if (!session) throw new Error("missing_session");
        const page = await call("goto", {url, waitUntil: "networkidle", timeout: 15000});
        if (page.result.isError) return text({url, error: page.body.slice(0, 500)});
        const markdown = await call("markdown", {maxBytes});
        const meta = page.result.structuredContent ?? {};
        return text({url: meta.url ?? url, status: meta.httpStatus ?? null, title: meta.title ?? null,
          markdown: markdown.body});
      } catch {
        throw new Error("Lightpanda request failed");
      } finally {
        if (session) fetch(endpoint, {method: "DELETE", headers: {"Mcp-Session-Id": session},
          signal: AbortSignal.timeout(5000)}).catch(() => {});
      }
    }

    function browserTools(api) {
      return {
        camofox_create_tab: ctx => ({
          description: "Open a new Camoufox tab at a URL. Pass the profile named in the task to use that logged-in account; omit it for an anonymous throwaway session. The first tab binds this session to that choice.",
          parameters: {type: "object", additionalProperties: false, properties: {
            url: {type: "string"}, profile: {type: "string", pattern: profilePattern},
          }, required: ["url"]},
          async execute(_id, params) {
            const url = checkedUrl(params?.url);
            const { userId, sessionKey, profile } = identity(ctx, params?.profile ?? "");
            const payload = await localRequest(api, "/tabs", {body: {url, userId, sessionKey}});
            if (typeof payload?.tabId !== "string") throw new Error("Invalid tab response");
            return text({tabId: payload.tabId, url: payload.url, profile});
          },
        }),
        camofox_snapshot: ctx => ({
          description: "Get a text-only accessibility snapshot with refs and offset pagination",
          parameters: {type: "object", additionalProperties: false, properties: {
            tabId: {type: "string"}, offset: {type: "integer", minimum: 0}
          }, required: ["tabId"]},
          async execute(_id, params) {
            if (params.offset != null && (!Number.isSafeInteger(params.offset) || params.offset < 0))
              throw new Error("Invalid snapshot offset");
            const query = new URLSearchParams({userId: identity(ctx).userId, includeScreenshot: "false"});
            if (params.offset != null) query.set("offset", String(params.offset));
            const payload = await localRequest(api, `/tabs/''${tabPath(params)}/snapshot?''${query}`);
            if (!payload || typeof payload !== "object" || Array.isArray(payload))
              throw new Error("Invalid snapshot response");
            const {screenshot: _ignored, ...rest} = payload;
            return text(rest);
          },
        }),
        camofox_list_tabs: ctx => ({
          description: "List the Camoufox tabs opened by this session.",
          parameters: {type: "object", additionalProperties: false, properties: {}},
          async execute() {
            const { userId, sessionKey, profile } = identity(ctx);
            const payload = await localRequest(api, `/tabs?''${new URLSearchParams({userId})}`);
            const tabs = (Array.isArray(payload?.tabs) ? payload.tabs : [])
              .filter(tab => tab?.listItemId === sessionKey)
              .map(({tabId, url, title}) => ({tabId, url, title}));
            return text({profile, tabs});
          },
        }),
        camofox_close_tab: ctx => ({
          description: "Close a Camoufox tab opened by this session.",
          parameters: {type: "object", additionalProperties: false, properties: {
            tabId: {type: "string"},
          }, required: ["tabId"]},
          async execute(_id, params) {
            const path = tabPath(params);
            const { userId } = identity(ctx);
            const scopeId = `''${backendUrl(api)}:''${userId}`;
            const status = tabState.inspect(scopeId, params.tabId).status;
            if (status !== "available" && status !== "tab_quarantined")
              throw new Error("Tab unavailable; close blocked during active execution");
            // A close on a quarantined tab never clears quarantine. An available
            // tab uses the same lease as execution, acquired before dispatch.
            const lease = status === "available" ? tabState.acquire(scopeId, params.tabId) : null;
            let outcome = "not_dispatched";
            try {
              if (lease) { lease.markMutation(); outcome = "unknown"; }
              const ack = await localRequest(api, `/tabs/''${path}?''${new URLSearchParams({userId})}`, {method: "DELETE"});
              if (ack?.ok !== true) throw new Error("Tab close outcome unknown");
              outcome = "verified";
              return text(ack);
            } catch { throw new Error("Tab close outcome unknown; inspect before further action"); }
            finally { lease?.release({outcome}); }
          },
        }),
        lightpanda_read: () => ({
          description: "Read a public page, including JavaScript-rendered content, as markdown with the lightweight Lightpanda browser. No login, no interaction; it is detectable as a bot, so use Camoufox for protected or logged-in sites.",
          parameters: {type: "object", additionalProperties: false, properties: {
            url: {type: "string"}, maxBytes: {type: "integer", minimum: 1000, maximum: 60000},
          }, required: ["url"]},
          execute: (_id, params) => lightpandaRead(api, params),
        }),
      };
    }

    // Owner logins use their own tab group, apart from agent sessions; Alfred
    // only receives the viewer link and cookie counts, never page content.
    const loginSessionKey = "owner-login";
    function loginTools(api) {
      const viewer = () => {
        try {
          const url = new URL(api.pluginConfig?.viewerUrl);
          if (url.protocol !== "https:" || url.username || url.password) throw Error();
          return url.href;
        } catch { throw new Error("Browser login viewer is not configured"); }
      };
      const profileParameters = {profile: {type: "string", pattern: profilePattern}};
      return {
        browser_login_open: () => ({
          description: "Open a URL in a browser profile so the owner can log in through the remote viewer. Send the owner the returned viewerUrl; after they confirm, call browser_login_save.",
          parameters: {type: "object", additionalProperties: false, properties: {
            ...profileParameters, url: {type: "string"},
          }, required: ["profile", "url"]},
          async execute(_id, params) {
            const userId = profileUserId(params?.profile);
            const viewerUrl = viewer();
            const payload = await localRequest(api, "/tabs",
              {body: {url: checkedUrl(params.url), userId, sessionKey: loginSessionKey}});
            if (typeof payload?.tabId !== "string") throw new Error("Invalid tab response");
            return text({profile: params.profile, viewerUrl});
          },
        }),
        browser_login_save: () => ({
          description: "Persist the owner's login in a browser profile and close its login tabs. Returns only cookie and origin counts.",
          parameters: {type: "object", additionalProperties: false, properties: profileParameters,
            required: ["profile"]},
          async execute(_id, params) {
            const userId = profileUserId(params?.profile);
            let state;
            try {
              state = await localRequest(api, `/sessions/''${userId}/storage_state`, {maxBytes: 8_000_000});
            } catch {
              // Camofox also persists a profile when its idle session closes.
              return text({profile: params.profile, saved: false,
                reason: "No open login session; verify the login by opening the site in this profile."});
            }
            const listed = await localRequest(api, `/tabs?''${new URLSearchParams({userId})}`);
            for (const tab of Array.isArray(listed?.tabs) ? listed.tabs : []) {
              if (tab?.listItemId !== loginSessionKey) continue;
              await localRequest(api, `/tabs/''${tabPath(tab)}?''${new URLSearchParams({userId})}`, {method: "DELETE"})
                .catch(() => {});
            }
            return text({profile: params.profile, saved: true,
              cookies: Array.isArray(state?.cookies) ? state.cookies.length : 0,
              origins: Array.isArray(state?.origins) ? state.origins.length : 0});
          },
        }),
      };
    }

    function gatedFactory(factory, agentId) {
      return ctx => {
        if (ctx?.agentId !== agentId) return undefined;
        const tool = factory(ctx);
        if (!tool || typeof tool !== "object" || typeof tool.name !== "string" || typeof tool.execute !== "function")
          throw new Error("Camofox plugin rejected malformed tool registration");
        return tool;
      };
    }

    function registerRecoveryCommand(api) {
      if (typeof api.registerCommand !== "function" || typeof tabState.incident !== "function" ||
          typeof tabState.trustedRecover !== "function") throw Error("Browser recovery requires the native command and incident ledger");
      const reply = text => ({ text });
      const safeIncident = id => {
        if (!/^[0-9a-f]{32}$/.test(id)) return null;
        const incident = tabState.incident(id);
        if (!incident || typeof incident.scope !== "string" ||
            typeof incident.tabId !== "string" || !/^[\w-]{1,128}$/.test(incident.tabId)) return null;
        const prefix = `''${backendUrl(api)}:`;
        if (!incident.scope.startsWith(prefix)) return null;
        const userId = incident.scope.slice(prefix.length);
        if (!/^[0-9a-f]{64}$/.test(userId)) return null;
        return { ...incident, userId };
      };
      async function observe(incident) {
        // A snapshot alone is not a settlement barrier: Camofox can release a
        // timed-out tab lock while the underlying mutation is still running.
        const path = `/tabs/''${encodeURIComponent(incident.tabId)}/settlement?''${new URLSearchParams({userId: incident.userId})}`;
        const settlement = await localRequest(api, path);
        if (settlement?.ok !== true || !["settled", "closed"].includes(settlement.state))
          throw Error("settlement_not_confirmed");
        if (settlement.state === "closed") return { state: "closed", fingerprint: "closed", evidence: "Tab is closed; no page evidence is available." };
        const browser = createCamofoxBrowser({baseUrl: backendUrl(api), userId: incident.userId,
          accessKey: process.env.CAMOFOX_ACCESS_KEY});
        const snapshot = await browser.snapshot(incident.tabId, {signal: AbortSignal.timeout(15_000)});
        if (typeof snapshot?.snapshot !== "string" || typeof snapshot?.url !== "string" ||
            snapshot.hasMore === true || snapshot.truncated === true) throw Error("incomplete_recovery_snapshot");
        const evidence = snapshot.snapshot.split("\n")
          .filter(line => /^\s*- (?:heading|paragraph|alert)\b/.test(line) &&
            !/password|passphrase|secret|token|api.key|credential|card|cvv|cvc|\bpin\b|\botp\b|account.number|authorization/i.test(line))
          .map(line => line.replace(/\[[eE][0-9]+\]/g, "")
            .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[email]")
            .replace(/\b(?:\+?\d[\d .()-]{7,}\d)\b/g, "[number]"))
          .join("\n").replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 600);
        return { state: "settled", fingerprint: createHash("sha256")
          .update(JSON.stringify([snapshot.url, snapshot.snapshot, snapshot.structure])).digest("hex"), evidence };
      }
      api.registerCommand({
        name: "browser_recover", description: "Owner-only review and acknowledgement of a settled quarantined browser tab",
        channels: ["telegram"], acceptsArgs: true, requireAuth: true,
        async handler(ctx) {
          // Native command context, never a tool/session parameter. Authorization
          // precedes incident lookup, network access, and disclosure of state.
          if (ctx?.isAuthorizedSender !== true || ctx.channel !== "telegram" ||
              typeof ctx.senderId !== "string" || !/^[1-9][0-9]*$/.test(ctx.senderId) ||
              ctx.from !== `telegram:''${ctx.senderId}` ||
              !Array.isArray(ctx.config?.commands?.ownerAllowFrom) ||
              !ctx.config.commands.ownerAllowFrom.includes(`telegram:''${ctx.senderId}`))
            return reply("Browser recovery requires the authorized owner.");
          const match = /^([0-9a-f]{32}) (inspect|ack)$/.exec(ctx.args?.trim() ?? "");
          if (!match) return reply("Usage: /browser_recover <incidentId> inspect|ack");
          const [, id, operation] = match;
          try {
            const incident = safeIncident(id);
            const inspected = incident && tabState.inspect(incident.scope, incident.tabId);
            if (!incident || inspected.status !== "tab_quarantined" || inspected.incidentId !== id)
              return reply("Incident unavailable or no longer quarantined.");
            const key = `''${ctx.senderId}:''${id}`;
            if (operation === "inspect") {
              inspectedIncidents.delete(key);
              const seen = await observe(incident);
              inspectedIncidents.set(key, { state: seen.state, fingerprint: seen.fingerprint, at: Date.now() });
              return reply(`Remote tab is ''${seen.state}; fresh page evidence (untrusted and abbreviated): ''${seen.evidence || "No readable headings or text."}\nReview the effects before acknowledging. To retire this quarantine without retrying the action, send /browser_recover ''${id} ack within five minutes. This does not establish business success.`);
            }
            const seen = inspectedIncidents.get(key);
            inspectedIncidents.delete(key);
            if (!seen || Date.now() - seen.at > 300_000) return reply("Inspect this incident first; acknowledgement expired.");
            const recovered = await tabState.trustedRecover(incident.scope, incident.tabId, {
              freshVerified: async () => {
                const currentIncident = tabState.incident(id);
                if (!currentIncident || currentIncident.scope !== incident.scope ||
                    currentIncident.tabId !== incident.tabId) return false;
                const current = await observe(incident);
                return current.state === seen.state && current.fingerprint === seen.fingerprint;
              },
              confirm: async () => true,
            });
            if (recovered) {
              const eventId = randomBytes(16).toString("base64url");
              observations.emit({event: "recovery_result", run_id: eventId, task_id: eventId,
                task_count: 1, incident_id: id, status: "verified", owner: "user"});
            }
            return reply(recovered ? "Quarantine retired after operator acknowledgement. This is not proof of business completion; never automatically retry the original action." :
              "State changed or recovery was unavailable; quarantine retained. Inspect again.");
          } catch {
            return reply("Remote settlement or fresh observation could not be verified; quarantine retained.");
          }
        },
      });
    }

    export default function register(api) {
      const registerTool = api?.registerTool;
      if (typeof registerTool !== "function")
        throw new TypeError("OpenClaw API has no registerTool method");

      const registerAll = (tools, agentId) => {
        for (const [name, factory] of Object.entries(tools))
          registerTool.call(api, gatedFactory(ctx => ({name, ...factory(ctx)}), agentId), {name});
      };
      registerAll(browserTools(api), "browser");
      registerAll(loginTools(api), "main");
      const scopedApi = {registerTool(factory, options) {
        return registerTool.call(api, gatedFactory(factory, "browser"), options);
      }};
      registerLocalBrowserExecutor(scopedApi, {
        scope: ctx => identity(ctx).userId,
        executable: "${lib.getExe browser-decision}",
        baseUrl: backendUrl(api),
        accessKey: process.env.CAMOFOX_ACCESS_KEY,
        observations, tabState,
      });
      registerBrowserObservations({registerTool(factory, options) {
        return registerTool.call(api, ctx => ctx?.agentId === "main" ? factory(ctx) : undefined, options);
      }}, {observations});
      registerRecoveryCommand(api);
    }
    EOF
    runHook postInstall
  '';

  passthru = {
    source = camofox-browser-source;
  };

  meta = {
    description = "OpenClaw Camofox browser plugin with a restricted tool surface";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = camofox-browser-source.meta.platforms;
  };
}

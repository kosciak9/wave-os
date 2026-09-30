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
  allowedTools = [
    "camofox_create_tab"
    "camofox_snapshot"
    "camofox_close_tab"
    "camofox_list_tabs"
  ];
  allowedToolsJson = builtins.toJSON allowedTools;
  advertisedTools = allowedTools ++ [
    "browser_execute"
    "browser_resolve"
    "browser_observations"
  ];
  advertisedToolsJson = builtins.toJSON advertisedTools;
in
stdenvNoCC.mkDerivation {
  pname = "camofox-openclaw-plugin";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    jq --argjson allowed '${allowedToolsJson}' --arg version ${lib.escapeShellArg version} \
          ' .version = $version
          | .main = "plugin.js"
           | .files = [ "plugin.js", "openclaw.plugin.json" ]
           | .openclaw.extensions = [ "plugin.js" ]
           | .openclaw.runtimeExtensions = [ "plugin.js" ]
           | .openclaw.tools = ([ .openclaw.tools[] | select(.name as $name | ($allowed | index($name)) != null) |
                if .name == "camofox_snapshot" then .description = "Text-only accessibility snapshot with offset pagination" else . end ] +
                  [{name: "browser_execute", description: "Start bounded local browser execution"},
                   {name: "browser_resolve", description: "Resolve a single-use browser execution handoff"},
                   {name: "browser_observations", description: "Read bounded value-free browser operation observations"}])
           | del(.bin, .scripts, .dependencies, .optionalDependencies, .devDependencies,
               .peerDependencies, .peerDependenciesMeta, .overrides)' \
           '${camofox-browser-source}/package.json' > "$out/package.json"
    jq --argjson allowed '${advertisedToolsJson}' --arg version ${lib.escapeShellArg version} \
           '.version = $version | .tools = $allowed | .contracts.tools = $allowed' \
          '${camofox-browser-source}/openclaw.plugin.json' > "$out/openclaw.plugin.json"
    cat > "$out/plugin.js" <<'EOF'
    import { createHash, createHmac, randomBytes } from "node:crypto";
    import registerUpstream from "${camofox-browser-source}/plugin.js";
    import { registerLocalBrowserExecutor, registerBrowserObservations } from "${executorRuntime}/plugin.mjs";
    import { createCamofoxBrowser } from "${executorRuntime}/camofox.mjs";
    import { createObservationStore } from "${executorRuntime}/observations.mjs";
    import { createTabState } from "${executorRuntime}/state.mjs";

    const allowedTools = new Set(${allowedToolsJson});
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

    async function localRequest(api, path, body) {
      const key = process.env.CAMOFOX_ACCESS_KEY;
      if (!key) throw new Error("Camofox access key is required");
      try {
        const response = await fetch(new URL(path, backendUrl(api)), {
          method: body ? "POST" : "GET", redirect: "error",
          signal: AbortSignal.timeout(15000),
          headers: { Authorization: `Bearer ''${key}`, ...(body ? {"Content-Type": "application/json"} : {}) },
          ...(body ? {body: JSON.stringify(body)} : {}),
        });
        if (!response.ok) throw new Error("backend_unavailable");
        if (Number(response.headers.get("content-length")) > 250000) {
          await response.body?.cancel();
          throw new Error("response_too_large");
        }
        let text = "";
        let size = 0;
        const decoder = new TextDecoder();
        for await (const chunk of response.body) {
          size += chunk.byteLength;
          if (size > 250000) throw new Error("response_too_large");
          text += decoder.decode(chunk, {stream: true});
        }
        text += decoder.decode();
        return JSON.parse(text);
      } catch {
        throw new Error("Camofox local request failed");
      }
    }

    function localTool(name, api, ctx) {
      const userId = ctx.agentId;
      const tab = params => {
        if (typeof params.tabId !== "string" || !/^[\w-]{1,128}$/.test(params.tabId))
          throw new Error("Invalid tab ID");
        return encodeURIComponent(params.tabId);
      };
      const text = payload => ({ content: [{type: "text", text: JSON.stringify(payload)}] });
      if (name === "camofox_snapshot") return {
        name, description: "Get a text-only accessibility snapshot with refs and offset pagination",
        parameters: {type: "object", additionalProperties: false, properties: {
          tabId: {type: "string"}, offset: {type: "integer", minimum: 0}
        }, required: ["tabId"]},
        async execute(_id, params) {
          if (params.offset != null && (!Number.isSafeInteger(params.offset) || params.offset < 0))
            throw new Error("Invalid snapshot offset");
          const query = new URLSearchParams({userId, includeScreenshot: "false"});
          if (params.offset != null) query.set("offset", String(params.offset));
          const payload = await localRequest(api, `/tabs/''${tab(params)}/snapshot?''${query}`);
          if (!payload || typeof payload !== "object" || Array.isArray(payload))
            throw new Error("Invalid snapshot response");
          const {screenshot: _ignored, ...rest} = payload;
          return text(rest);
        },
      };
      throw new Error("Unexpected local tool");
    }

    function scopedContext(args) {
      const context = args[0];
      if (!context || typeof context !== "object")
        throw new Error("Camofox plugin requires a scoped tool context");

      const scope = [context.sessionKey, context.sessionId].find(
        (value) => typeof value === "string" && value.length > 0,
      );
      const accessKey = process.env.CAMOFOX_ACCESS_KEY;
      if (!scope || typeof accessKey !== "string" || accessKey.length === 0)
        throw new Error("Camofox plugin requires scoped identity and access key");

      const identity = createHmac("sha256", accessKey).update(scope).digest("hex");
      return [{ ...context, agentId: identity, sessionKey: identity }, ...args.slice(1)];
    }

    // The raw factory context is the authority; the HMAC replacement is only
    // a Camofox namespace, never a trustworthy actor identity.
    function browserFactory(factory, name, api) {
      return (...args) => {
        if (args[0]?.agentId !== "browser") return undefined;
        const scoped = scopedContext(args);
        const tool = name === "camofox_snapshot" ? localTool(name, api, scoped[0]) : factory(...scoped);
        if (!tool || typeof tool !== "object" || tool.name !== name || typeof tool.execute !== "function")
          throw new Error("Camofox plugin rejected malformed tool registration");
        if (name === "camofox_create_tab") return {...tool, async execute(id, params) {
          try {
            if (typeof params?.url !== "string" || params.url.length > 2048) throw Error();
            const url = new URL(params.url);
            if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw Error();
          } catch { throw new Error("Invalid tab URL"); }
          return tool.execute.call(tool, id, params);
        }};
        if (name === "camofox_close_tab") return {...tool, async execute(id, params) {
          if (typeof params?.tabId !== "string" || !/^[\w-]{1,128}$/.test(params.tabId))
            throw new Error("Invalid tab ID");
          const scopeId = `''${backendUrl(api)}:''${scoped[0].agentId}`;
          const status = tabState.inspect(scopeId, params.tabId).status;
          if (status !== "available" && status !== "tab_quarantined")
            throw new Error("Tab unavailable; close blocked during active execution");
          // A close on a quarantined tab never clears quarantine. An available
          // tab uses the same lease as execution, acquired before dispatch.
          const lease = status === "available" ? tabState.acquire(scopeId, params.tabId) : null;
          let outcome = "not_dispatched";
          try {
            if (lease) { lease.markMutation(); outcome = "unknown"; }
            const result = await tool.execute.call(tool, id, params);
            const ack = JSON.parse(result.content?.[0]?.text);
            if (ack?.ok !== true) throw new Error("Tab close outcome unknown");
            outcome = "verified";
            return result;
          } catch { throw new Error("Tab close outcome unknown; inspect before further action"); }
          finally { lease?.release({outcome}); }
        }};
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

      const proxy = new Proxy(api, {
        get(target, property) {
          if (["registerCommand", "registerHealthCheck", "registerRpc", "registerCli"].includes(property))
            return () => {};
          if (property === "registerTool") {
            return (factory, options) => {
              const name = options?.name;
              if (typeof name !== "string" || !allowedTools.has(name) || typeof factory !== "function")
                return;
              return registerTool.call(target, browserFactory(factory, name, api), { ...options, name });
            };
          }
          const value = Reflect.get(target, property, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });

      const result = registerUpstream(proxy);
      const scopedApi = {registerTool(factory, options) {
        return registerTool.call(api, browserFactory(factory, options.name, api), options);
      }};
      registerLocalBrowserExecutor(scopedApi, {
        scope: ctx => ctx.agentId,
        executable: "${lib.getExe browser-decision}",
        baseUrl: backendUrl(api),
        accessKey: process.env.CAMOFOX_ACCESS_KEY,
        observations, tabState,
      });
      registerBrowserObservations({registerTool(factory, options) {
        return registerTool.call(api, ctx => ctx?.agentId === "main" ? factory(ctx) : undefined, options);
      }}, {observations});
      registerRecoveryCommand(api);
      return result;
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

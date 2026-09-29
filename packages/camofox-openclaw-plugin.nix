{
  stdenvNoCC,
  jq,
  lib,
  camofox-browser-source,
  enableExecutor ? false,
  browser-decision ? null,
}:

let
  executorEnabled = enableExecutor && browser-decision != null;
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
        ]
      );
  };
  # Experimental Laya native candidate; measured locally, not calibrated for production.
  executorDefaults = {
    backend = "laya";
    maxSteps = 24;
    timeoutMs = 120000;
    threshold = 0.5;
    margin = 0.05;
    candidateMode = "strictBindings";
    applyPrepared = true;
    representation = "current";
    history = 0;
    stopPolicy = "success";
    contractMode = "semantic";
    semanticProblemDetail = "contextual";
    semanticBoundary = "adaptive";
    resolverOptions = {
      useAliases = true;
      useContext = true;
      trackProgress = true;
    };
  };
  executorDefaultsJson = builtins.toJSON executorDefaults;
  inherit (camofox-browser-source) version;
  allowedTools = [
    "camofox_create_tab"
    "camofox_snapshot"
    "camofox_select"
    "camofox_click"
    "camofox_type"
    "camofox_navigate"
    "camofox_scroll"
    "camofox_screenshot"
    "camofox_close_tab"
    "camofox_list_tabs"
  ];
  allowedToolsJson = builtins.toJSON allowedTools;
  advertisedTools = allowedTools ++ lib.optional executorEnabled "browser_execute";
  advertisedToolsJson = builtins.toJSON advertisedTools;
in
assert !enableExecutor || browser-decision != null;
stdenvNoCC.mkDerivation {
  pname = "camofox-openclaw-plugin";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ jq ];

  installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        jq --argjson allowed '${allowedToolsJson}' --argjson executor ${
          if executorEnabled then "true" else "false"
        } --arg version ${lib.escapeShellArg version} \
          ' .version = $version
          | .main = "plugin.js"
           | .files = [ "plugin.js", "openclaw.plugin.json" ]
           | .openclaw.extensions = [ "plugin.js" ]
           | .openclaw.runtimeExtensions = [ "plugin.js" ]
           | .openclaw.tools = ([ .openclaw.tools[] | select(.name as $name | ($allowed | index($name)) != null) |
                if .name == "camofox_snapshot" then .description = "Text-only accessibility snapshot with offset pagination" else . end ] +
                [{name: "camofox_select", description: "Select an option in a native select by snapshot ref"}] +
                (if $executor then [{name: "browser_execute", description: "Bounded local browser execution"}] else [] end))
           | del(.bin, .scripts, .dependencies, .optionalDependencies, .devDependencies,
               .peerDependencies, .peerDependenciesMeta, .overrides)' \
           '${camofox-browser-source}/package.json' > "$out/package.json"
        jq --argjson defaults '${executorDefaultsJson}' --argjson allowed '${advertisedToolsJson}' --arg version ${lib.escapeShellArg version} \
          '.version = $version | .tools = $allowed | .contracts.tools = $allowed |
            .configSchema.properties.browserExecutor = {
              type: "object", additionalProperties: false,
              properties: {enabled: {type: "boolean", default: false},
                backend: {type: "string", enum: ["kev", "laya"], default: $defaults.backend},
                maxSteps: {type: "integer", minimum: 1, maximum: 24, default: $defaults.maxSteps},
                timeoutMs: {type: "integer", minimum: 1000, maximum: 120000, default: $defaults.timeoutMs},
                threshold: {type: "number", minimum: 0, maximum: 1, default: $defaults.threshold},
                margin: {type: "number", minimum: 0, maximum: 1, default: $defaults.margin},
                candidateMode: {type: "string", enum: ["legacy", "strictBindings"], default: $defaults.candidateMode},
                applyPrepared: {type: "boolean", default: $defaults.applyPrepared},
                representation: {type: "string", enum: ["full", "current"], default: $defaults.representation},
                history: {type: "integer", enum: [0, 2], default: $defaults.history},
                stopPolicy: {type: "string", enum: ["checkpoint", "success"], default: $defaults.stopPolicy},
                contractMode: {type: "string", enum: ["procedural", "semantic"], default: $defaults.contractMode},
                semanticProblemDetail: {type: "string", enum: ["compact", "contextual"], default: $defaults.semanticProblemDetail},
                semanticBoundary: {type: "string", enum: ["conservative", "adaptive"], default: $defaults.semanticBoundary},
                resolverOptions: {type: "object", additionalProperties: false, properties: {
                  useAliases: {type: "boolean", default: true}, useContext: {type: "boolean", default: true},
                  trackProgress: {type: "boolean", default: true}}}}
            }' \
          '${camofox-browser-source}/openclaw.plugin.json' > "$out/openclaw.plugin.json"
        cat > "$out/plugin.js" <<'EOF'
    import { createHmac } from "node:crypto";
    import registerUpstream from "${camofox-browser-source}/plugin.js";
    ${lib.optionalString executorEnabled ''
      import { createValueFreeMetricSink, registerHybridBrowserExecutor } from "${executorRuntime}/plugin.mjs";
      import { browserTabMutationAllowed } from "${executorRuntime}/core.mjs";
      import { reserveBrowserTabMutation } from "${executorRuntime}/core.mjs";
    ''}

    const allowedTools = new Set(${allowedToolsJson});
    const executorDefaults = ${executorDefaultsJson};

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
      return {
        name, description: "Select a native select option using a current snapshot ref and option value",
        parameters: {type: "object", additionalProperties: false, properties: {
          tabId: {type: "string"}, ref: {type: "string", pattern: "^e[0-9]{1,6}$"},
          option: {type: "string", minLength: 1, maxLength: 160}
        }, required: ["tabId", "ref", "option"]},
        async execute(_id, params) {
          if (typeof params.ref !== "string" || !/^e[0-9]{1,6}$/.test(params.ref) ||
              typeof params.option !== "string" || !params.option || params.option.length > 160)
            throw new Error("Invalid select input");
          return text(await localRequest(api, `/tabs/''${tab(params)}/select`,
            {userId, ref: params.ref, option: params.option}));
        },
      };
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

    ${lib.optionalString executorEnabled ''
      // Process-local lease survives tool calls, not gateway restarts. A restart
      // loses quarantine state even if the remote action later completes: inspect
      // the tab and verify its effects before allowing any further mutation.
      function guardMutation(tool, name, api, scoped) {
        if (!["camofox_click", "camofox_type", "camofox_navigate", "camofox_scroll", "camofox_select"].includes(name))
          return tool;
        if (typeof tool.execute !== "function") throw new Error("Camofox tool has no execute method");
        const execute = tool.execute;
        return {...tool, async execute(_id, params) {
          const tabId = params?.tabId;
          if (typeof tabId !== "string" || !/^[\w-]{1,128}$/.test(tabId))
            throw new Error("Invalid tab ID");
          const scopeId = `''${backendUrl(api)}:''${scoped.agentId}`;
          // Claim synchronously, before any await or network dispatch. A
          // read-only check alone has a check-to-dispatch race with the executor.
          let release;
          try {
            release = reserveBrowserTabMutation(scopeId, tabId);
          } catch {
            throw new Error("Browser tab has an unresolved local action; inspect before mutating");
          }
          let ok = false;
          try {
            const response = await execute.call(tool, _id, params);
            ok = true;
            return response;
          } catch {
            // A rejected/aborted request may still finish on the browser server.
            // Never leak an upstream error or access key to the model.
            throw new Error("Browser mutation outcome uncertain; inspect before mutating");
          } finally {
            release({ok});
          }
        }};
      }
    ''}

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
              const guardedFactory = (...args) => {
                const scoped = scopedContext(args);
                const original = name === "camofox_snapshot" ? localTool(name, api, scoped[0]) : factory(...scoped);
                const tool = ${
                  if executorEnabled then "guardMutation(original, name, api, scoped[0])" else "original"
                };
                if (!tool || typeof tool !== "object" || tool.name !== name || !allowedTools.has(tool.name))
                  throw new Error("Camofox plugin rejected malformed tool registration");
                return tool;
              };
              return registerTool.call(target, guardedFactory, { ...options, name });
            };
          }
          const value = Reflect.get(target, property, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });

      const result = registerUpstream(proxy);
      registerTool.call(api, ctx => {
        const scoped = scopedContext([ctx])[0];
        const tool = localTool("camofox_select", api, scoped);
        return ${
          if executorEnabled then ''guardMutation(tool, "camofox_select", api, scoped)'' else "tool"
        };
      }, { name: "camofox_select" });
      ${lib.optionalString executorEnabled ''
        if (api.pluginConfig?.browserExecutor?.enabled === true) {
           const cfg = {...executorDefaults, ...api.pluginConfig.browserExecutor};
           if (!(!Object.hasOwn(api.pluginConfig.browserExecutor, "defaultPolicy") &&
                  ["kev", "laya"].includes(cfg.backend) &&
                  Number.isInteger(cfg.maxSteps) && cfg.maxSteps >= 1 && cfg.maxSteps <= 24 &&
                  Number.isInteger(cfg.timeoutMs) && cfg.timeoutMs >= 1000 && cfg.timeoutMs <= 120000 &&
                  typeof cfg.threshold === "number" && Number.isFinite(cfg.threshold) && cfg.threshold >= 0 && cfg.threshold <= 1 &&
                  typeof cfg.margin === "number" && Number.isFinite(cfg.margin) && cfg.margin >= 0 && cfg.margin <= 1 &&
                  ["legacy", "strictBindings"].includes(cfg.candidateMode) &&
                  typeof cfg.applyPrepared === "boolean" && (!cfg.applyPrepared || cfg.candidateMode === "strictBindings") &&
                  ["full", "current"].includes(cfg.representation) && [0, 2].includes(cfg.history) &&
                  ["checkpoint", "success"].includes(cfg.stopPolicy) &&
                  ["procedural", "semantic"].includes(cfg.contractMode) &&
                  ["compact", "contextual"].includes(cfg.semanticProblemDetail) &&
                  ["conservative", "adaptive"].includes(cfg.semanticBoundary) &&
                  cfg.resolverOptions && typeof cfg.resolverOptions === "object" && !Array.isArray(cfg.resolverOptions) &&
                  Object.keys(cfg.resolverOptions).every(k => ["useAliases", "useContext", "trackProgress"].includes(k)) &&
                  Object.values(cfg.resolverOptions).every(v => typeof v === "boolean")))
            throw new Error("Invalid browser executor configuration");
          const telemetry = createValueFreeMetricSink(process.env.WAVE_HYBRID_METRICS_PATH);
          registerHybridBrowserExecutor({
            registerTool(factory, options) {
              return registerTool.call(api, ctx => factory(scopedContext([ctx])[0]), options);
            },
          }, {
            scope: ctx => ctx.agentId,
            executable: "${lib.getExe browser-decision}",
             backend: cfg.backend, baseUrl: backendUrl(api),
             accessKey: process.env.CAMOFOX_ACCESS_KEY,
              maxSteps: cfg.maxSteps, timeoutMs: cfg.timeoutMs,
              threshold: cfg.threshold, margin: cfg.margin,
              candidateMode: cfg.candidateMode, applyPrepared: cfg.applyPrepared,
              representation: cfg.representation, history: cfg.history, stopPolicy: cfg.stopPolicy,
              contractMode: cfg.contractMode, defaultPolicy: "strict", resolverOptions: cfg.resolverOptions,
              semanticProblemDetail: cfg.semanticProblemDetail,
              semanticBoundary: cfg.semanticBoundary,
              telemetry, onMetric: telemetry,
          });
        }
      ''}
      return result;
    }
    EOF
        runHook postInstall
  '';

  passthru = {
    source = camofox-browser-source;
    inherit executorEnabled;
    inherit executorDefaults;
  };

  meta = {
    description = "OpenClaw Camofox browser plugin with a restricted tool surface";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = camofox-browser-source.meta.platforms;
  };
}

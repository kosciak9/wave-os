{
  stdenvNoCC,
  jq,
  lib,
  camofox-browser-source,
}:

let
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
                [{name: "camofox_select", description: "Select an option in a native select by snapshot ref"}])
           | del(.bin, .scripts, .dependencies, .optionalDependencies, .devDependencies,
               .peerDependencies, .peerDependenciesMeta, .overrides)' \
           '${camofox-browser-source}/package.json' > "$out/package.json"
        jq --argjson allowed '${allowedToolsJson}' --arg version ${lib.escapeShellArg version} \
          '.version = $version | .tools = $allowed | .contracts.tools = $allowed' \
          '${camofox-browser-source}/openclaw.plugin.json' > "$out/openclaw.plugin.json"
        cat > "$out/plugin.js" <<'EOF'
    import { createHmac } from "node:crypto";
    import registerUpstream from "${camofox-browser-source}/plugin.js";

     const allowedTools = new Set(${allowedToolsJson});

     function redactSensitiveSnapshot(payload) {
       if (!payload || typeof payload !== "object" || Array.isArray(payload))
         throw new Error("Invalid snapshot response");
       const {screenshot: _ignored, ...rest} = payload;
       const sensitive = /password|passphrase/i;
       const values = [];
       if (rest.structure?.forms && Array.isArray(rest.structure.forms))
         rest.structure = {...rest.structure, forms: rest.structure.forms.map(form => ({...form,
           fields: Array.isArray(form.fields) ? form.fields.map(field => {
             if (!field || !(field.type === "password" || sensitive.test(`''${field.label ?? ""} ''${field.name ?? ""}`)))
               return field;
             if (typeof field.value === "string" && field.value.length >= 4) values.push(field.value);
             return {...field, value: "[REDACTED]"};
           }) : form.fields,
         }))};
       if (typeof rest.snapshot === "string") {
         rest.snapshot = rest.snapshot.replace(/^([^\n]*\b(?:textbox|input)\b[^\n]*(?:password|passphrase)[^\n]*?\]:) [^\n]+/gim,
           "$1 [REDACTED]");
         for (const value of values) rest.snapshot = rest.snapshot.replaceAll(value, "[REDACTED]");
       }
       return rest;
     }

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
           return text(redactSensitiveSnapshot(await localRequest(api,
             `/tabs/''${tab(params)}/snapshot?''${query}`)));
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
                const tool = name === "camofox_snapshot" ? localTool(name, api, scoped[0]) : factory(...scoped);
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
      registerTool.call(api, ctx => localTool("camofox_select", api, scopedContext([ctx])[0]),
        { name: "camofox_select" });
      return result;
    }
    EOF
        runHook postInstall
  '';

  passthru.source = camofox-browser-source;

  meta = {
    description = "OpenClaw Camofox browser plugin with a restricted tool surface";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = camofox-browser-source.meta.platforms;
  };
}

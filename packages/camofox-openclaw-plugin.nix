{
  stdenvNoCC,
  jq,
  lib,
  camofox-browser-source,
}:

let
  allowedTools = [
    "camofox_create_tab"
    "camofox_snapshot"
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
  version = "1.15.0";

  dontUnpack = true;

  nativeBuildInputs = [ jq ];

  installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        jq --argjson allowed '${allowedToolsJson}' \
          ' .version = "1.15.0"
          | .main = "plugin.js"
           | .files = [ "plugin.js", "openclaw.plugin.json" ]
           | .openclaw.extensions = [ "plugin.js" ]
           | .openclaw.runtimeExtensions = [ "plugin.js" ]
           | .openclaw.tools = [ .openclaw.tools[] | select(.name as $name | ($allowed | index($name)) != null) ]
           | del(.scripts, .dependencies, .optionalDependencies, .devDependencies,
               .peerDependencies, .peerDependenciesMeta, .overrides)' \
           '${camofox-browser-source}/package.json' > "$out/package.json"
        jq --argjson allowed '${allowedToolsJson}' \
          '.version = "1.15.0" | .tools = $allowed | .contracts.tools = $allowed' \
          '${camofox-browser-source}/openclaw.plugin.json' > "$out/openclaw.plugin.json"
        cat > "$out/plugin.js" <<'EOF'
    import { createHmac } from "node:crypto";
    import registerUpstream from "${camofox-browser-source}/plugin.js";

    const allowedTools = new Set([
      "camofox_create_tab",
      "camofox_snapshot",
      "camofox_click",
      "camofox_type",
      "camofox_navigate",
      "camofox_scroll",
      "camofox_screenshot",
      "camofox_close_tab",
      "camofox_list_tabs",
    ]);

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
                const tool = factory(...scopedContext(args));
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

      return registerUpstream(proxy);
    }
    EOF
        runHook postInstall
  '';

  passthru.source = camofox-browser-source;

  meta = {
    description = "OpenClaw Camofox browser plugin with a restricted tool surface";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}

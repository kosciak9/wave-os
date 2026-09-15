{ stdenvNoCC, lib }:

stdenvNoCC.mkDerivation {
  pname = "openclaw-home-assistant-mcp-resolver";
  version = "1.0.0";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cat > "$out/package.json" <<'EOF'
    {
      "name": "home-assistant-mcp-resolver",
      "version": "1.0.0",
      "type": "module",
      "main": "plugin.js",
      "files": ["plugin.js", "openclaw.plugin.json"],
      "openclaw": {
        "extensions": ["plugin.js"],
        "runtimeExtensions": ["plugin.js"]
      }
    }
    EOF
    cat > "$out/openclaw.plugin.json" <<'EOF'
    {
      "id": "home-assistant-mcp-resolver",
      "name": "Home Assistant MCP resolver",
      "description": "Requester-scoped Home Assistant MCP connection resolver.",
      "activation": { "onStartup": true },
      "configSchema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {}
      }
    }
    EOF
    cat > "$out/plugin.js" <<'EOF'
    const HOME_ASSISTANT_URL = /^http:\/\/pikachu:9584\/private_[A-Za-z0-9]+$/;

    export default function register(api) {
      api.registerMcpServerConnectionResolver({
        serverName: "home-assistant",
        resolve(request) {
          const requesterSenderId = request?.requesterSenderId;
          const url = process.env.HOME_ASSISTANT_MCP_URL;
          if (
            typeof requesterSenderId !== "string" ||
            requesterSenderId.length === 0 ||
            typeof url !== "string" ||
            !HOME_ASSISTANT_URL.test(url) ||
            HOME_ASSISTANT_URL.exec(url)?.[0] !== url
          ) {
            return null;
          }
          return { url };
        },
      });
    }
    EOF
    runHook postInstall
  '';

  meta = {
    description = "Requester-scoped Home Assistant MCP connection resolver for OpenClaw";
    homepage = "https://github.com/openclaw/openclaw";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
}

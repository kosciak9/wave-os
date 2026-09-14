{
  fetchFromGitea,
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  adapterRev = "616c822e4be208e23695ccdb1afff9f2bdbbb760";
  languageToolVersion = "6.6";
  platform = "linux-arm64";
  debianSnapshot = "20260914T000000Z";
in
stdenvNoCC.mkDerivation {
  pname = "openclaw-languagetool-mcp-context";
  version = "1.1.0-6.6";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "dpesch";
    repo = "languagetool-mcp-server";
    rev = adapterRev;
    hash = "sha256-fuo50z0ddYZre++pq3289p5MVdbyIrH+EYX46wlKfQo=";
  };

  languageToolZip = fetchurl {
    url = "https://languagetool.org/download/LanguageTool-6.6.zip";
    hash = "sha256-U2AFBrOZu1/+HkyN7HlP03ghLxSq84zO+bb4kxTRFjE=";
  };

  patches = [ ./languagetool-mcp-cli.patch ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/adapter" "$out/languagetool"
    cp -a ./. "$out/adapter/"
    install -Dm644 "$languageToolZip" "$out/languagetool/LanguageTool-${languageToolVersion}.zip"
    cat > "$out/Dockerfile" <<'EOF'
    FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241 AS build

    ENV DEBIAN_FRONTEND=noninteractive

    RUN rm -f /etc/apt/sources.list.d/debian.sources \
      && printf '%s\n' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${debianSnapshot}/ bookworm main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${debianSnapshot}/ bookworm-updates main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${debianSnapshot}/ bookworm-security main' \
        > /etc/apt/sources.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends ca-certificates nodejs npm unzip \
      && rm -rf /var/lib/apt/lists/*

    WORKDIR /src
    COPY adapter/ ./
    COPY languagetool/LanguageTool-${languageToolVersion}.zip /tmp/LanguageTool-${languageToolVersion}.zip

    RUN npm ci \
      && npm run build \
      && npm run typecheck \
      && npm prune --omit=dev \
      && mkdir -p /opt/languagetool \
      && unzip -q /tmp/LanguageTool-${languageToolVersion}.zip -d /opt/languagetool \
      && rm /tmp/LanguageTool-${languageToolVersion}.zip

    FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

    ENV DEBIAN_FRONTEND=noninteractive \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        LT_CLI_JAR=/opt/languagetool/LanguageTool-${languageToolVersion}/languagetool-commandline.jar \
        LT_JAVA_BIN=/usr/bin/java \
        NODE_ENV=production \
        HOME=/tmp

    RUN rm -f /etc/apt/sources.list.d/debian.sources \
      && printf '%s\n' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${debianSnapshot}/ bookworm main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${debianSnapshot}/ bookworm-updates main' \
        'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${debianSnapshot}/ bookworm-security main' \
        > /etc/apt/sources.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends nodejs openjdk-17-jre-headless \
      && rm -rf /var/lib/apt/lists/* \
      && groupadd --gid 65532 wave \
      && useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin wave

    COPY --from=build /src/dist /opt/adapter/dist
    COPY --from=build /src/node_modules /opt/adapter/node_modules
    COPY --from=build /src/package.json /opt/adapter/package.json
    COPY --from=build /src/LICENSE /opt/adapter/LICENSE
    COPY --from=build /opt/languagetool /opt/languagetool

    LABEL org.opencontainers.image.title="LanguageTool MCP server" \
          org.opencontainers.image.version="${languageToolVersion}" \
          org.opencontainers.image.source="https://codeberg.org/dpesch/languagetool-mcp-server" \
          org.opencontainers.image.revision="${adapterRev}" \
          io.wave-os.component="openclaw-languagetool-mcp" \
          io.wave-os.adapter-commit="${adapterRev}" \
          io.wave-os.languagetool-version="${languageToolVersion}" \
          io.wave-os.debian-snapshot="${debianSnapshot}"

    USER 65532:65532
    WORKDIR /tmp
    ENTRYPOINT ["node", "/opt/adapter/dist/index.js"]
    EOF
    runHook postInstall
  '';

  passthru = {
    adapterCommit = adapterRev;
    inherit debianSnapshot languageToolVersion platform;
  };

  meta = {
    description = "Deterministic OpenClaw LanguageTool MCP Docker build context";
    homepage = "https://codeberg.org/dpesch/languagetool-mcp-server";
    license = with lib.licenses; [
      mit
      lgpl21Plus
    ];
    platforms = lib.platforms.all;
  };
}

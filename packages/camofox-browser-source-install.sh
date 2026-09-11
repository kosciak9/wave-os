runHook preInstall
substituteInPlace Dockerfile \
  --replace-fail \
    'FROM node:22-trixie-slim AS camofox-browser' \
    'FROM docker.io/library/node:22-trixie-slim@sha256:7b8a0c89c54499bee567618f96578e1a12a800f062fbdbfd1fb6a443fa6f6284 AS camofox-browser'
substituteInPlace Dockerfile \
  --replace-fail \
    'ARG ARCH=x86_64' \
    'ARG ARCH=arm64
ARG CAMOUFOX_SHA256=3a105a2fc929e80a79b4b7fce2c93ed62c4fb2c877f3c1ed2a5d66a1c4fe968f'
substituteInPlace server.js \
  --replace-fail \
    '        humanize: true,' \
    '        humanize: true,
        block_webrtc: true,'
substituteInPlace server.js \
  --replace-fail \
    'app.use(accessKeyMiddleware(CONFIG));' \
    'app.use(accessKeyMiddleware(CONFIG));

// Wave OS does not permit arbitrary page-context evaluation.
app.all("/tabs/:tabId/evaluate", (_req, res) => res.status(404).json({ error: "Not found" }));'
substituteInPlace Dockerfile \
  --replace-fail \
    '# Install dependencies for Camoufox (Firefox-based)
RUN apt-get update && apt-get install -y \' \
    '# Install dependencies for Camoufox (Firefox-based)
RUN printf "%s\n" \
  "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99snapshot \
  && printf "%s\n" \
  "Types: deb" "URIs: http://snapshot.debian.org/archive/debian/20260901T000000Z/" \
  "Suites: trixie trixie-updates" "Components: main" "Check-Valid-Until: false" \
  > /etc/apt/sources.list.d/debian.sources \
  && printf "%s\n" \
  "Types: deb" "URIs: http://snapshot.debian.org/archive/debian-security/20260901T000000Z/" \
  "Suites: trixie-security" "Components: main" "Check-Valid-Until: false" \
  > /etc/apt/sources.list.d/debian-security.sources \
  && apt-get update && apt-get install -y \'
substituteInPlace Dockerfile \
  --replace-fail \
    '    ca-certificates \
    curl \
    unzip \' \
    '    ca-certificates \
    curl \
    unzip \
    squid \'
substituteInPlace Dockerfile \
  --replace-fail \
    '    && (unzip -q /tmp/camoufox.zip -d /root/.cache/camoufox || true)' \
    '    && echo "${CAMOUFOX_SHA256}  /tmp/camoufox.zip" | sha256sum -c - \
    && (unzip -q /tmp/camoufox.zip -d /root/.cache/camoufox || true)'
substituteInPlace Dockerfile \
  --replace-fail \
    'ENV CAMOFOX_PORT=9377

EXPOSE 9377

CMD ["sh", "-c", "node --max-old-space-size=${MAX_OLD_SPACE_SIZE:-128} server.js"]' \
    'ENV CAMOFOX_PORT=9377

EXPOSE 9377

COPY squid.conf /etc/squid/squid.conf
COPY camofox-entrypoint.sh /usr/local/bin/camofox-entrypoint
RUN squid -k parse -f /etc/squid/squid.conf
RUN chmod 0755 /usr/local/bin/camofox-entrypoint

CMD ["/usr/local/bin/camofox-entrypoint"]'
cat > squid.conf <<'EOF'
http_port 127.0.0.1:3128
cache deny all
access_log none
cache_log none
forwarded_for delete
visible_hostname camofox-egress

acl Safe_ports port 80 443
acl SSL_ports port 443
acl CONNECT method CONNECT

acl blocked_dst dst 0.0.0.0/8
acl blocked_dst dst 10.0.0.0/8
acl blocked_dst dst 100.64.0.0/10
acl blocked_dst dst 127.0.0.0/8
acl blocked_dst dst 169.254.0.0/16
acl blocked_dst dst 172.16.0.0/12
acl blocked_dst dst 192.0.0.0/24
acl blocked_dst dst 192.0.2.0/24
acl blocked_dst dst 192.88.99.0/24
acl blocked_dst dst 192.168.0.0/16
acl blocked_dst dst 198.18.0.0/15
acl blocked_dst dst 198.51.100.0/24
acl blocked_dst dst 203.0.113.0/24
acl blocked_dst dst 224.0.0.0/4
acl blocked_dst dst 240.0.0.0/4
acl blocked_dst dst ::/128
acl blocked_dst dst ::1/128
acl blocked_dst dst fc00::/7
acl blocked_dst dst fe80::/10
acl blocked_dst dst ff00::/8

http_access deny blocked_dst
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost
http_access deny all
EOF
cat > camofox-entrypoint.sh <<'EOF'
#!/bin/bash
set -eu
squid_pid=
node_pid=
interrupted=0

forward_signal() {
  interrupted=1
  [ -z "$squid_pid" ] || kill -TERM "$squid_pid" 2>/dev/null || true
  [ -z "$node_pid" ] || kill -TERM "$node_pid" 2>/dev/null || true
}

trap 'forward_signal' INT TERM HUP

squid -f /etc/squid/squid.conf -N &
squid_pid=$!
ready=0
attempt=0
while [ "$attempt" -lt 50 ]; do
  running_jobs=$(jobs -pr)
  if [ -z "$running_jobs" ]; then
    if wait "$squid_pid"; then squid_status=0; else squid_status=$?; fi
    [ "$squid_status" -ne 0 ] || squid_status=1
    exit "$squid_status"
  fi
  if curl --silent --show-error --noproxy "" --max-time 1 --connect-timeout 1 \
      --proxy http://127.0.0.1:3128 http://127.0.0.1:3128/ >/dev/null 2>&1; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$interrupted" -ne 0 ]; then
  if wait "$squid_pid"; then squid_status=0; else squid_status=$?; fi
  [ "$squid_status" -ne 0 ] || squid_status=1
  exit "$squid_status"
fi
if [ "$ready" -ne 1 ]; then
  kill -TERM "$squid_pid" 2>/dev/null || true
  if wait "$squid_pid"; then :; else :; fi
  echo "Squid failed to become ready" >&2
  exit 1
fi

node --max-old-space-size="${MAX_OLD_SPACE_SIZE:-128}" server.js &
node_pid=$!
if wait -n -p failed_pid "$squid_pid" "$node_pid"; then failed_status=0; else failed_status=$?; fi
if [ "$interrupted" -ne 0 ]; then
  kill -TERM "$squid_pid" "$node_pid" 2>/dev/null || true
  if wait "$squid_pid"; then :; else :; fi
  if wait "$node_pid"; then :; else :; fi
  exit 1
fi
[ "$failed_status" -ne 0 ] || failed_status=1
if [ "$failed_pid" = "$squid_pid" ]; then
  other_pid=$node_pid
else
  other_pid=$squid_pid
fi
kill -TERM "$other_pid" 2>/dev/null || true
if wait "$other_pid"; then :; else :; fi
exit "$failed_status"
EOF
chmod 0644 squid.conf
chmod 0755 camofox-entrypoint.sh
# Security override for adm-zip's symlink-following extraction vulnerability.
jq '.packages."node_modules/adm-zip".version = "0.6.1"
  | .packages."node_modules/adm-zip".resolved = "https://registry.npmjs.org/adm-zip/-/adm-zip-0.6.1.tgz"
  | .packages."node_modules/adm-zip".integrity = "sha512-Xwrja8nx9e5o2N1my4DsKCeKpdrnACyr1wtbPxBDgGzKzKyE9kRtBFA8mWldI+RVlD7CBZNWY/wQ2+ydwOR6kQ=="' \
  package-lock.json > package-lock.json.tmp
mv package-lock.json.tmp package-lock.json
jq '.version = "1.15.0" | del(.plugins.vnc)' camofox.config.json > camofox.config.json.tmp
mv camofox.config.json.tmp camofox.config.json
mkdir -p "$out"
cp -R --no-preserve=ownership ./. "$out/"
runHook postInstall

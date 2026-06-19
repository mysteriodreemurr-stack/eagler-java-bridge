#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Render assigns $PORT dynamically and terminates TLS. This script renders the
# BungeeCord config from a template, points EaglercraftXServer's WebSocket
# listener at the same port, then launches the proxy.
# ---------------------------------------------------------------------------
set -euo pipefail

export PORT="${PORT:-25577}"
export SERVER="${SERVER:-mysteriodreemurr.falixsrv.me:24896}"
INJECT_ADDR="0.0.0.0:${PORT}"

cd /server

echo "==========================================================="
echo " Eaglercraft <-> Java bridge starting"
echo "   listen        : 0.0.0.0:${PORT}   (plain ws; Render adds TLS -> wss)"
echo "   backend SERVER : ${SERVER}        (plain TCP, ip_forward=false)"
echo "==========================================================="

# 1) BungeeCord config.yml  (ip_forward:false, online_mode:false, one listener,
#    default server = $SERVER). envsubst only expands the two vars we name, so
#    literal Bungee placeholders/$ in the template are left untouched.
envsubst '${PORT} ${SERVER}' < /server/templates/config.yml.template > /server/config.yml

# 2) EaglercraftXServer listener -> inject into the Bungee listener on $PORT.
#    EaglercraftXServer writes its config in TOML by default (the file is
#    plugins/EaglercraftXServer/listeners.toml; ".cfg" in the docs is a
#    placeholder for the real format extension). It's generated at BUILD time by
#    scripts/build-gen-config.sh. We detect whatever extension exists and patch
#    the value with sed -- format-agnostic, because the default inject_address
#    value "0.0.0.0:25577" looks the same token in TOML/YAML/JSON, and yq cannot
#    WRITE toml. If inject_address stays at the 25577 default it won't match
#    Bungee's 0.0.0.0:$PORT listener -> port stays raw Minecraft -> "Unexpected
#    packet... GET / HTTP/1.1" / Render "no open HTTP ports".
LISTENERS="$(ls /server/plugins/EaglercraftXServer/listeners.* 2>/dev/null | grep -vi '\.bak$' | head -1 || true)"
if [ -z "${LISTENERS:-}" ]; then
  echo "WARN: no generated listeners.* found -> using TOML fallback (verify build log)"
  mkdir -p /server/plugins/EaglercraftXServer
  LISTENERS="/server/plugins/EaglercraftXServer/listeners.toml"
  cp /server/templates/listeners.toml.fallback "$LISTENERS"
fi
echo "Patching listener config: $LISTENERS"

# Critical: rewrite the inject_address host:port to 0.0.0.0:$PORT on its line.
# Matches any IPv4:port token so it works whether the default is 25577 or other.
sed -i -E "/inject_address/ s#[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+#0.0.0.0:${PORT}#" "$LISTENERS"
# Best-effort: recover the real client IP from Render's X-Forwarded-For header
# (otherwise every Eagler player shares Render's load-balancer address).
sed -i -E "s/(forward_ip[[:space:]]*[:=][[:space:]]*)(false|true)/\1true/"          "$LISTENERS" || true
sed -i -E "s/(forward_ip_header[[:space:]]*[:=][[:space:]]*[\"']?)X-Real-IP([\"']?)/\1X-Forwarded-For\2/" "$LISTENERS" || true

echo "----- effective inject_address / forward_ip in $LISTENERS -----"
grep -iE "inject_address|forward_ip" "$LISTENERS" || true
# Hard guard: refuse to launch if the port still didn't get into inject_address.
if ! grep -qE "inject_address.*:${PORT}([^0-9]|$)" "$LISTENERS"; then
  echo "FATAL: inject_address was not patched to port ${PORT}; dumping file:"; cat "$LISTENERS"; exit 1
fi

# 3) EaglerWeb: if it generated a web root, drop our landing page in so the
#    Render URL serves something. (Best-effort: schema not guaranteed.)
for webroot in /server/plugins/EaglerWeb/web /server/plugins/EaglerWeb/webserver; do
  if [ -d "$webroot" ]; then
    echo "Publishing landing page into $webroot"
    cp -f /server/web/index.html "$webroot/index.html" 2>/dev/null || true
  fi
done

echo "Launching BungeeCord..."
exec java -Xms128M "-Xmx${MAX_MEMORY:-460M}" -jar /server/BungeeCord.jar

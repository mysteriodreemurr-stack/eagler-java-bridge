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
#    The config file on BungeeCord is listeners.cfg (NOT .yaml). Its *content*
#    is YAML, but the .cfg extension means yq can't infer the format, so we force
#    -p=yaml -o=yaml. If the default inject_address (0.0.0.0:25577) is left
#    unpatched it won't match Bungee's 0.0.0.0:$PORT listener and the port stays
#    raw Minecraft -> "Unexpected packet... GET / HTTP/1.1" / no open HTTP ports.
LISTENERS="/server/plugins/EaglercraftXServer/listeners.cfg"
if [ ! -f "$LISTENERS" ]; then
  echo "WARN: $LISTENERS missing (build-time generation produced none) -> using fallback template"
  mkdir -p /server/plugins/EaglercraftXServer
  cp /server/templates/listeners.cfg.fallback "$LISTENERS"
fi

# Patch the first listener: bind point + recover real client IP from Render's
# X-Forwarded-For (otherwise every Eagler player shares Render's LB address).
# dual_stack is left untouched (defaults true).
INJECT_ADDR="$INJECT_ADDR" yq -i -p=yaml -o=yaml '
  .listener_list[0].inject_address     = strenv(INJECT_ADDR) |
  .listener_list[0].forward_ip         = true |
  .listener_list[0].forward_ip_header  = "X-Forwarded-For"
' "$LISTENERS" || {
  echo "ERROR: failed to patch $LISTENERS; dumping it for debugging:"; cat "$LISTENERS" || true; exit 1;
}

echo "----- effective EaglercraftXServer listener (listeners.cfg) -----"
yq -p=yaml '.listener_list[0]' "$LISTENERS" || true

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

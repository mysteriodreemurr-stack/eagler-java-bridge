# ---------------------------------------------------------------------------
# Eaglercraft <-> Java bridge for Render free Web Service
#
# Topology:
#   Browser (Eagler 1.8 / 1.12 web client)  --wss-->  Render TLS edge
#       --ws (plain) on $PORT-->  THIS container
#           BungeeCord + EaglercraftXServer (NO ViaVersion here)
#       --plain TCP, ip_forward:false-->  FalixNodes Paper 26.1.2 backend
#           (the backend already runs ViaVersion/ViaBackwards/ViaRewind,
#            which do the 1.8<->26.x protocol translation)
#
# Why no Via on the bridge: lax1dude's README puts Via on the *backend*
# Spigot server, and ViaBungee (Via for BungeeCord) was discontinued at MC
# 1.20.2, so it cannot translate for a 26.x context anyway. BungeeCord
# natively pipes the 1.8 client through to the backend; the backend's Via
# stack does the translation. Putting Via here too would double-translate.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy

# --- Pinned versions (verified 2026-06; bump ARGs to update) ---------------
ARG BUNGEE_URL="https://ci.md-5.net/job/BungeeCord/lastSuccessfulBuild/artifact/bootstrap/target/BungeeCord.jar"
ARG EAGLERX_VERSION="v1.1.0"
ARG EAGLERX_URL="https://github.com/lax1dude/eaglerxserver/releases/download/${EAGLERX_VERSION}/EaglerXServer.jar"
ARG EAGLERWEB_URL="https://github.com/lax1dude/eaglerxserver/releases/download/${EAGLERX_VERSION}/EaglerWeb.jar"
ARG YQ_VERSION="v4.44.3"

# envsubst (gettext-base) for $PORT/$SERVER templating; yq for surgical YAML edits.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gettext-base \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq

WORKDIR /server

# Download the proxy + plugins at build time (Render's builder has internet).
RUN mkdir -p /server/plugins /server/templates \
 && curl -fsSL "$BUNGEE_URL"    -o /server/BungeeCord.jar \
 && curl -fsSL "$EAGLERX_URL"   -o /server/plugins/EaglerXServer.jar \
 && curl -fsSL "$EAGLERWEB_URL" -o /server/plugins/EaglerWeb.jar

# Boot the proxy once at BUILD time so EaglercraftXServer/EaglerWeb write their
# *own* default config files (authoritative key names) into the image. The
# entrypoint then only patches the handful of values that depend on $PORT/$SERVER.
# This avoids hand-guessing the plugin's YAML schema. Non-fatal if it times out.
RUN cd /server \
 && (timeout 45 java -Xmx256M -jar BungeeCord.jar > /tmp/firstboot.log 2>&1 || true) \
 && echo "================= firstboot.log =================" && cat /tmp/firstboot.log || true \
 && echo "================= generated config tree =========" \
 && ls -laR /server/plugins 2>/dev/null | head -n 120 || true

# Templates / web assets / entrypoint (copied last for better layer caching).
COPY templates/ /server/templates/
COPY web/       /server/web/
COPY entrypoint.sh /server/entrypoint.sh
RUN chmod +x /server/entrypoint.sh

# Defaults — override SERVER/MAX_MEMORY in the Render dashboard. PORT is injected
# by Render at runtime; the 25577 here is only a local-run fallback.
ENV PORT=25577 \
    SERVER=mysteriodreemurr.falixsrv.me:24896 \
    MAX_MEMORY=460M

EXPOSE 25577
ENTRYPOINT ["/server/entrypoint.sh"]

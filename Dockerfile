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

# envsubst (gettext-base) for $PORT/$SERVER templating. (No yq: config is patched
# with sed because EaglercraftXServer writes TOML, which yq cannot serialize.)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gettext-base \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /server

# Download the proxy + plugins at build time (Render's builder has internet).
RUN mkdir -p /server/plugins /server/templates \
 && curl -fsSL "$BUNGEE_URL"    -o /server/BungeeCord.jar \
 && curl -fsSL "$EAGLERX_URL"   -o /server/plugins/EaglerXServer.jar \
 && curl -fsSL "$EAGLERWEB_URL" -o /server/plugins/EaglerWeb.jar

# Boot the proxy ONCE at build time so EaglercraftXServer writes its real default
# config files into the image (so the entrypoint patches authoritative keys, not
# guesses). Must be a GRACEFUL boot: stdin held open + `end` command, otherwise
# the JVM EOF-shuts-down mid-onEnable and no configs are flushed. See the script.
COPY scripts/ /server/scripts/
RUN chmod +x /server/scripts/build-gen-config.sh \
 && /server/scripts/build-gen-config.sh

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

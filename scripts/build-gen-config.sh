#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BUILD-TIME ONLY. Boots BungeeCord once so EaglercraftXServer writes its real
# default config files (listeners.*, settings.*) into the image. The previous
# approach (`timeout 45 java ...`) failed because docker build hands the JVM a
# CLOSED stdin: BungeeCord's console reader hit EOF and shut the proxy down
# mid-onEnable, before the plugin flushed its configs (only eagcert/ +
# sqlite-jdbc.jar survived). Here we hold stdin open with a FIFO, wait until the
# proxy is fully up, then issue BungeeCord's graceful `end` command so onDisable
# runs and every config is flushed.
# ---------------------------------------------------------------------------
set -uo pipefail
cd /server

LOG=/tmp/firstboot.log
FIFO=/tmp/bcin
rm -f "$FIFO"; mkfifo "$FIFO"

# Start the proxy with the FIFO as stdin (never EOFs) so it stays alive.
java -Xmx256M -jar BungeeCord.jar < "$FIFO" > "$LOG" 2>&1 &
BCPID=$!
# Hold the write end open ourselves so the FIFO doesn't EOF.
exec 3>"$FIFO"

echo "[build] waiting for proxy to finish enabling (pid $BCPID)..."
UP=0
for i in $(seq 1 120); do
  if grep -qiE "Listening on|Enabled .*Eagler|Done \(|Listening on /" "$LOG"; then
    echo "[build] proxy reported up after ${i}s"; UP=1; break
  fi
  if ! kill -0 "$BCPID" 2>/dev/null; then echo "[build] proxy exited early after ${i}s"; break; fi
  sleep 1
done
[ "$UP" = 1 ] || echo "[build] WARN: never saw 'Listening' — sending end anyway"

# Let any late onEnable config writes settle, then stop gracefully.
sleep 4
echo "[build] sending 'end' for graceful shutdown..."
echo "end" >&3 || true

# Wait for a clean exit (gives onDisable time to flush).
for i in $(seq 1 40); do
  kill -0 "$BCPID" 2>/dev/null || { echo "[build] graceful stop after ${i}s"; break; }
  sleep 1
done
kill -TERM "$BCPID" 2>/dev/null || true
sleep 2
kill -9 "$BCPID" 2>/dev/null || true
exec 3>&- || true
rm -f "$FIFO"

echo "================== firstboot.log =================="
cat "$LOG" 2>/dev/null || true
echo "================== EaglercraftXServer dir ========="
ls -laR /server/plugins/EaglercraftXServer 2>/dev/null || echo "(dir missing)"
echo "================== generated config files ========="
found=0
for f in /server/plugins/EaglercraftXServer/listeners.* /server/plugins/EaglercraftXServer/settings.*; do
  [ -f "$f" ] || continue
  found=1
  echo "----------- $f -----------"
  cat "$f"
done
[ "$found" = 1 ] || echo "!!! No listeners.*/settings.* generated — entrypoint will use the TOML fallback !!!"
echo "==================================================="
# Never fail the build on this best-effort step.
exit 0

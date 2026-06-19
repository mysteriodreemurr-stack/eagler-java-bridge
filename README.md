# Eaglercraft ⇄ Java bridge for a Paper 26.1.2 (offline) backend

A tiny BungeeCord + **EaglercraftXServer** proxy you deploy on a **Render free
Web Service** (no credit card). It lets **Eaglercraft 1.8 / 1.12 browser
clients** join the **same** Minecraft world that modern *and* legacy **Java
Edition** clients already play on — at the same time.

```
Java client (any version) ──TCP──────────────► FalixNodes Paper 26.1.2
                                                (backend, bungeecord:false,
                                                 ViaVersion+ViaBackwards+ViaRewind)
                                                        ▲
Eagler 1.8/1.12 web client ──wss──► Render edge ──ws──► │  plain TCP, ip_forward:false
                                    (this bridge:        │
                                     BungeeCord +        ┘
                                     EaglercraftXServer,
                                     NO Via)
```

## Why it's built this way (the one decision that matters)

**ViaVersion is NOT on this bridge — it lives only on your backend (where it
already is).** Two independent facts force this:

1. lax1dude's EaglercraftXServer README says to install
   ViaVersion/ViaBackwards/ViaRewind **on the backend Spigot server**, not the
   proxy. EaglercraftXServer only converts the Eagler **WebSocket** transport
   into an ordinary Minecraft TCP stream — it does **not** translate versions.
2. **ViaBungee** (ViaVersion's BungeeCord build) was **discontinued at MC
   1.20.2**, so Via literally can't run on a BungeeCord bridge for a 26.x world.

BungeeCord natively pipes the 1.8 Eagler client through to the backend, and the
**backend's** Via stack does the 47↔26.x translation. The old
`qwedfrnhgef/eagler-viaversion` image bundled Via *on the bridge* only because
*its* backend was a vanilla 1.8 server with no Via. Your backend isn't — copying
that model would **double-translate** and corrupt the stream. Hence: replace it.

This also fixes the original breakage: the old image hardcoded BungeeCord
`ip_forward: true`, which a `bungeecord:false` backend rejects with *"Unknown
data in login hostname."* This bridge sets **`ip_forward: false`**.

## What's in here

| File | Purpose |
|------|---------|
| `Dockerfile` | `eclipse-temurin:17-jre` base. Downloads BungeeCord + EaglercraftXServer `v1.1.0` + EaglerWeb, then runs the graceful build boot. |
| `scripts/build-gen-config.sh` | BUILD-time: boots BungeeCord with stdin held open + `end` command so EaglercraftXServer flushes its real default config (`listeners.toml`) into the image. A plain `timeout`/kill boot does NOT work — the JVM EOF-shuts-down mid-`onEnable` and writes nothing. |
| `entrypoint.sh` | Substitutes `$PORT`/`$SERVER`, sed-patches EaglercraftXServer's `inject_address` to `0.0.0.0:$PORT` (format-agnostic), launches BungeeCord. Refuses to start if the patch didn't take. |
| `templates/config.yml.template` | BungeeCord config: `ip_forward:false`, `online_mode:false`, one listener on `$PORT`, default server = `$SERVER`. |
| `templates/listeners.toml.fallback` | Minimal EaglercraftXServer listener in TOML (its default format), used only if the build boot generated nothing. |
| `web/index.html` | Landing page served by EaglerWeb showing the `wss://` address to add. |
| `render.yaml` | Render Blueprint (free plan, `SERVER` env var). |

Pinned versions (verified June 2026): BungeeCord (latest CI), **EaglercraftXServer
v1.1.0** (2026-05-07), EaglerWeb v1.1.0. Backend keeps ViaVersion 5.9.1 /
ViaBackwards 5.9.1 / ViaRewind 4.1.1 — already current.

## Deploy on Render (exact steps)

1. **Push this folder to a public GitHub repo.**
2. Render Dashboard → **New → Web Service** → connect the repo (Render
   auto-detects the `Dockerfile`).
3. **Instance type: Free.** Region: closest to you / the backend.
4. **Environment variables** (Advanced):
   - `SERVER` = `mysteriodreemurr.falixsrv.me:24896`  *(host:port of the backend)*
   - `MAX_MEMORY` = `460M`  *(optional; default already 460M)*
   - **Do not set `PORT`** — Render injects it; the container binds `0.0.0.0:$PORT`.
5. **Create Web Service.** First build takes a few minutes (it boots the proxy
   once to generate configs). When live you get `https://<name>.onrender.com`.

*(Alternatively: New → Blueprint, point at this repo's `render.yaml`, then set
`SERVER`.)*

### Connecting

- **Easiest:** open any Eaglercraft client (e.g. a hosted EaglercraftX 1.8
  client), **Multiplayer → Add Server**, and paste **`wss://<name>.onrender.com/`**.
- Opening `https://<name>.onrender.com/` in a browser shows a landing page that
  prints the exact `wss://` address to add.
- **Java players** keep connecting to `mysteriodreemurr.falixsrv.me` directly —
  same world.

> Browsers block `ws://` from an `https://` page (mixed content). Always use
> **`wss://`** — Render provides the TLS, the container speaks plain `ws`.

## Free-tier behavior (expected, not bugs)

- **Render free sleeps after ~15 min idle**; first hit cold-starts in ~1 min.
- **FalixNodes free is ad-gated / sleeps** — start it (watch the ad) *before*
  connecting, or the bridge will fail to reach the backend.
- Render free Web Services are **HTTP/WebSocket only** (no raw TCP) — fine,
  Eaglercraft is WebSocket. This is also why the bridge can't host the
  backend↔proxy hop; that stays on FalixNodes.

## Acceptance test

| # | Test | Expected |
|---|------|----------|
| 1 | Modern Java client → `mysteriodreemurr.falixsrv.me` | joins directly |
| 2 | 1.8 Java client → same address | joins (backend Via translates) |
| 3 | Open the Render URL in a browser → Eagler client → the added `wss://` server | joins the **same** world; a Java player is visible; stable >2 min |
| 4 | Java + Eagler players see and interact with each other | one shared world |

## Troubleshooting

**"keepalive response without matching challenge" → "Timed out" (Eagler 1.8).**
This is a known **ViaRewind/Paper** legacy-keepalive strictness issue
([Paper#12888](https://github.com/PaperMC/Paper/issues/12888),
[ViaRewind#611](https://github.com/ViaVersion/ViaRewind/issues/611)), **on the
backend**, not the bridge. Paper times the keepalive round-trip against the main
thread, so a 1.8 client stutter (low FPS) trips it. Fixes, in order:
1. Keep ViaVersion/ViaBackwards/ViaRewind up to date on the backend.
2. Add **ViaRewind-Legacy-Support** to the backend plugins.
3. Lower the backend **`view-distance`** (e.g. 4–6) — large view distances on
   low-bandwidth Eagler connections also cause *"End of stream"* drops.
4. Reduce client-side FPS stalls; keep the bridge close to the backend region.

**"Unknown data in login hostname" on the backend.** `ip_forward` leaked back to
`true`. It must be `false` here (it is, in `config.yml.template`). Keep the
backend `spigot.yml` `bungeecord: false`.

**Render: "no open ports detected" / 502.** The container must bind
`0.0.0.0:$PORT`. Don't set a `PORT` env var; don't hardcode a port.

**1.8 client connects to the bridge but bounces at the backend.** Confirm the
backend is awake (FalixNodes ad started) and `online-mode=false`. Check the
Render logs — `entrypoint.sh` prints the effective listener and backend address.

**`Unexpected packet received during login process! 4554...` / Render "No open
HTTP ports detected".** The Eagler listener's `inject_address` didn't match the
BungeeCord listener, so the port stayed raw Minecraft (`4554...` decodes to
`GET / HTTP/1.1`). EaglercraftXServer writes its config as
`plugins/EaglercraftXServer/listeners.toml` (TOML; the `.cfg` in the docs is a
placeholder). `entrypoint.sh` sed-patches `inject_address` to `0.0.0.0:$PORT` and
**refuses to launch** if that didn't take, printing the file. Two upstream causes
this guards against: (a) the build boot didn't generate `listeners.toml` — check
the build log's "generated config files" dump (a non-graceful boot writes
nothing); (b) the file is in an unexpected format — confirm the dumped
`inject_address` line.

**EaglercraftXServer logs a config error / the landing page 404s.** EaglerWeb's
web-root path isn't guaranteed across versions. Deploy once, open the Render
**Shell**, find the generated `plugins/EaglercraftXServer/listeners.toml` and
`plugins/EaglerWeb/` layout, then (a) commit the generated `listeners.toml` as a
richer fallback and/or (b) adjust the `web/` copy target in `entrypoint.sh`.

## Updating versions

Bump the `ARG` values in the `Dockerfile`
(`EAGLERX_VERSION`, `BUNGEE_URL`, `YQ_VERSION`) and redeploy.

---

### Status / what was and wasn't verified

- **Architecture & versions: researched and verified** against the
  EaglercraftXServer README/CONFIG, ViaVersion/ViaBungee docs, and Render docs
  (June 2026).
- **Live deploy + the 4 acceptance tests: NOT run from here** — they need your
  Render + FalixNodes accounts and a browser against the live backend. The repo
  is build-ready; run the steps above and use Troubleshooting for the keepalive
  case if it appears.
- **Soft spots flagged in code/README:** the exact EaglercraftXServer
  `listeners.toml` schema and EaglerWeb's web-root path are version-dependent;
  the build-time-generate + patch approach uses the plugin's own defaults to
  stay correct, with a fallback if generation is skipped.

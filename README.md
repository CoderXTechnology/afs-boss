# AFS Boss Auto-Joiner + Auto-Farm

A port of [`adrielemir208-eng/Steal-a-brainrot-auto-joiner`](https://github.com/adrielemir208-eng/Steal-a-brainrot-auto-joiner)
rewritten for **Anime Fighting Simulator (AFS)**.

It detects specific bosses, farms them with an always-on camera aimbot, and posts
Discord notifications through a small Node server — exactly the architecture of the
original repo, adapted to how AFS actually works.

## Repo structure

```
.
├── afs-boss-autofarm.luau     # in-game script (load this in your executor)
├── afs-notifier/              # Node notifier backend (Discord webhooks)
│   ├── server.js
│   ├── package.json
│   ├── .env.example
│   └── README.md
├── .gitignore
└── README.md                  # this file
```

## What was copied from the GitHub repo

- **Notifier** — `HttpService` POST of `{ placeId, jobId, bosses[] }` to your Node
  server, 30s dedup, `x-notifier-token` auth (port of `sendNotifier`).
- **`fetchRealServers`** — Roblox `games.roblox.com` public-server API.
- **`joinServer`** — `TeleportService:TeleportToPlaceInstance` + `queue_on_teleport`
  bootstrap so the script re-runs after a teleport (port of the original hop logic).
- **Hop loop** — walks the server list and teleports to the next server when no
  target spawns.

## AFS-specific behaviour

- **No test mode** — auto-join and farm are ON by default.
- **No AimHandler hook** — an own always-on camera aimbot points the camera at the
  boss every frame, plus a real `VirtualInputManager` special-key press (Z by default).
- **Event-driven detection only** — `CollectionService` `isBoss` signal, zero workspace
  scans (stays under AFS anticheat).
- **Targets**
  - HIGH (tier 1 → `WEBHOOK_HIGH`): `FoundingTitan` (Dimension 2 only), `Mada["Phase-1"]`
  - LOW  (tier 2 → `WEBHOOK_LOW`): `HandDemon`, `SeaBeast`, `Shukaku`

## Setup

### 1. Notifier server (Deploy to Render / any Node host)

```bash
cd afs-notifier
npm install
cp .env.example .env        # then edit .env with your Discord webhooks
npm start
```

Set in `.env`:

| Key | Value |
|-----|-------|
| `WEBHOOK_LOW`  | Discord webhook for low-tier bosses (HandDemon / SeaBeast / Shukaku) |
| `WEBHOOK_HIGH` | Discord webhook for high-tier bosses (FoundingTitan / Mada) |
| `SECRET_TOKEN` | optional — if set, the script must send `x-notifier-token` |
| `PORT` | auto-set by Render |

Note the deployed URL, e.g. `https://your-service.onrender.com`.

### 2. In-game script

1. Load `afs-boss-autofarm.luau` in your executor.
2. Click the 🎯 button, paste your notifier URL into `Notifier URL (/data)`, click **Save**.
3. Equip a **special** (the farm fires special keys — without one it can't deal damage).
4. Toggle targets as needed. Auto-Join and Farm are ON by default.

## ⚠️ Server hopping is limited for AFS

AFS's universe (`10321202755`) is **rejected** by Roblox's public server-listing API
(`"The place is invalid"`), so the automatic server scan cannot fetch a server list for
this game (verified live — other games like Blox Fruits return 200). The faithful
enumeration code is kept (it will work if the API ever resolves) but the reliable way to
move between Dimension 2 servers is the **"paste JobId → Join"** box in the UI, which
hops via `TeleportToPlaceInstance`.

## Security

The Node server ships with **placeholder** webhook URLs in `.env.example`. Never commit
your real `.env` (see `.gitignore`). The in-game script sends no credentials.

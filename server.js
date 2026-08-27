// =============================================================================
//  AFS BOSS NOTIFIER  ·  port of the Steal-a-Brainrot auto-joiner server.js
//  Adapted for Anime Fighting Simulator (universe 10321202755).
//
//  Receives boss spottings from the in-game script (POST /data) and forwards
//  them to Discord webhooks split by tier:
//      tier 1 (HIGH) -> WEBHOOK_HIGH
//      tier 2 (LOW)  -> WEBHOOK_LOW
//  Each alert carries a Roblox join link so you can hop straight to the server.
// =============================================================================

import express from "express";
import fetch from "node-fetch";
import dotenv from "dotenv";
dotenv.config();

const app = express();
app.use(express.json());

const WEBHOOK_LOW  = process.env.WEBHOOK_LOW  || "";
const WEBHOOK_HIGH = process.env.WEBHOOK_HIGH || "";
const SECRET_TOKEN = process.env.SECRET_TOKEN || "";
const PORT         = process.env.PORT || 3000;

let lastLow = null;
let lastHigh = null;
let lastPayloads = [];

const rate = {};      // ip -> [timestamps]
const dedup = {};      // jobId_name -> timestamp

function authorized(req) {
  if (!SECRET_TOKEN) return true;
  return req.headers["x-notifier-token"] === SECRET_TOKEN;
}
function rateLimited(ip) {
  const now = Date.now();
  rate[ip] = (rate[ip] || []).filter((t) => now - t < 15000);
  if (rate[ip].length >= 30) return true;
  rate[ip].push(now);
  return false;
}

async function sendEmbed(boss, payload, webhookUrl) {
  if (!webhookUrl) return;
  const placeId = payload.placeId || "";
  const jobId = payload.jobId || "";
  const joinLink = `https://www.roblox.com/games/start?placeId=${placeId}&gameInstanceId=${jobId}`;
  const embed = {
    username: "AFS Boss Finder",
    embeds: [
      {
        title: boss.name + (boss.tier === 1 ? "  [HIGH TIER]" : "  [LOW TIER]"),
        color: boss.tier === 1 ? 16742400 : 5763719,
        fields: [
          { name: "Boss", value: boss.name || "?", inline: true },
          { name: "HP", value: (boss.hp != null ? String(boss.hp) : "?"), inline: true },
          { name: "Server Players", value: String(boss.players != null ? boss.players : (payload.players != null ? payload.players : "?")), inline: true },
          { name: "Join Link", value: `[Click to join](${joinLink})`, inline: false },
        ],
      },
    ],
  };
  await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(embed),
  });
}

app.post("/data", async (req, res) => {
  try {
    if (!authorized(req)) return res.status(401).json({ ok: false, error: "unauthorized" });
    const ip = req.headers["x-forwarded-for"] || req.socket.remoteAddress || "?";
    if (rateLimited(ip)) return res.status(429).json({ ok: false, error: "rate limited" });

    const payload = req.body || {};
    const bosses = (payload.bosses || []).filter((b) => b && b.name);
    if (bosses.length === 0) return res.json({ ok: true, sent: 0 });

    let sent = 0;
    for (const b of bosses) {
      const key = (payload.jobId || "") + "_" + b.name;
      const now = Date.now();
      if (dedup[key] && now - dedup[key] < 60000) continue; // 60s dedup
      dedup[key] = now;

      const wh = b.tier === 1 ? WEBHOOK_HIGH : WEBHOOK_LOW;
      await sendEmbed(b, payload, wh);
      const rec = { name: b.name, hp: b.hp, placeId: payload.placeId, jobId: payload.jobId, players: payload.players };
      if (b.tier === 1) lastHigh = rec; else lastLow = rec;
      sent++;
    }

    lastPayloads.unshift({ time: new Date().toISOString(), jobId: payload.jobId, bosses });
    lastPayloads = lastPayloads.slice(0, 50);
    res.json({ ok: true, sent });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get("/notifications/high", (_req, res) => res.json(lastHigh || {}));
app.get("/notifications/low", (_req, res) => res.json(lastLow || {}));
app.get("/health", (_req, res) => res.json({ ok: true, status: "healthy" }));
app.get("/status", (_req, res) =>
  res.json({
    ok: true,
    webhooksConfigured: !!(WEBHOOK_LOW && WEBHOOK_HIGH),
    authEnabled: !!SECRET_TOKEN,
    uptime: process.uptime(),
  })
);
app.get("/debug/last", (_req, res) => res.json(lastPayloads));

app.listen(PORT, () => console.log(`AFS boss notifier listening on ${PORT}`));

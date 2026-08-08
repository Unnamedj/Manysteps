import express from "express";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

import {
  BRIDGE_KEY,
  PANEL_PASSWORD,
  checkPassword,
  clearSessionCookie,
  createSession,
  destroySession,
  generatedBridgeKey,
  generatedPassword,
  isValidSession,
  requireBridgeAuth,
  requirePanelAuth,
  sessionFromRequest,
  setSessionCookie,
} from "./auth.js";
import * as store from "./store.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const PORT = Number(process.env.PORT) || 3000;

const app = express();
app.set("trust proxy", 1);
app.use(express.json({ limit: "256kb" }));

/* ------------------------------------------------------------------ */
/* validación de comandos                                              */
/* ------------------------------------------------------------------ */

const ID_RE = /^\d{1,19}$/;
const JOB_RE = /^[A-Za-z0-9-]{1,64}$/;

const COMMANDS = {
  "time.pause": () => ({}),
  "time.resume": () => ({}),
  "players.refresh": () => ({}),

  "settings.placeId"(payload) {
    const placeId = String(payload.placeId ?? "").trim();
    if (!ID_RE.test(placeId)) throw new Error("placeId debe ser numérico");
    return { placeId };
  },

  "settings.jobId"(payload) {
    const jobId = String(payload.jobId ?? "").trim();
    if (!JOB_RE.test(jobId)) {
      // Decir qué llegó ahorra mucho tiempo cuando se pega un Job ID
      // con comillas, espacios o algún carácter invisible de más.
      throw new Error(
        `Job ID inválido: "${jobId.slice(0, 60)}" (${jobId.length} caracteres). ` +
          `Se esperan solo letras, números y guiones.`,
      );
    }
    return { jobId };
  },

  "teleport.send"(payload) {
    const userId = String(payload.userId ?? "").trim();
    if (!ID_RE.test(userId)) throw new Error("userId debe ser numérico");

    const settings = store.currentSettings();
    const placeId = String(payload.placeId ?? settings.placeId ?? "").trim();
    if (!ID_RE.test(placeId)) throw new Error("placeId debe ser numérico");

    const jobId = String(payload.jobId ?? settings.jobId ?? "").trim();
    if (!JOB_RE.test(jobId)) throw new Error("falta un Job ID válido");

    const username = String(payload.username ?? "").slice(0, 40);
    return { userId, placeId, jobId, username };
  },
};

/* ------------------------------------------------------------------ */
/* API del panel                                                       */
/* ------------------------------------------------------------------ */

app.post("/api/auth/login", (req, res) => {
  if (!checkPassword(req.body?.password)) {
    return res.status(401).json({ error: "Contraseña incorrecta" });
  }
  setSessionCookie(res, createSession());
  res.json({ ok: true });
});

app.post("/api/auth/logout", (req, res) => {
  destroySession(sessionFromRequest(req));
  clearSessionCookie(res);
  res.json({ ok: true });
});

app.get("/api/auth/status", (req, res) => {
  res.json({ authenticated: isValidSession(sessionFromRequest(req)) });
});

app.get("/api/state", requirePanelAuth, (_req, res) => {
  res.json({ ...store.snapshot(), log: store.recentLog() });
});

/**
 * Estado compacto para el mando de Roblox. El /api/state completo lleva
 * el log entero, demasiado para pedirlo cada segundo y medio desde el
 * juego; aquí van solo las últimas líneas.
 */
app.get("/api/control/state", requirePanelAuth, (_req, res) => {
  const state = store.snapshot();
  res.json({
    serverTime: state.serverTime,
    bridge: {
      online: state.bridge.online,
      username: state.bridge.username,
      jobId: state.bridge.jobId,
    },
    time: state.time,
    settings: { placeId: state.settings.placeId, jobId: state.settings.jobId },
    game: { panelJobId: state.game.panelJobId },
    players: state.players.list,
    pending: state.pending,
    log: store.recentLog().slice(0, 6).map((entry) => ({
      at: entry.at,
      level: entry.level,
      message: entry.message,
    })),
  });
});

app.get("/api/bootstrap", requirePanelAuth, (req, res) => {
  const base = publicBaseUrl(req);
  res.json({
    baseUrl: base,
    bridgeKey: BRIDGE_KEY,
    loader: `loadstring(game:HttpGet("${base}/script/loader.lua?key=${BRIDGE_KEY}"))()`,
    controlLoader: `loadstring(game:HttpGet("${base}/script/loader.lua?key=${BRIDGE_KEY}&mode=control"))()`,
  });
});

app.post("/api/command", requirePanelAuth, (req, res) => {
  const type = String(req.body?.type ?? "");
  const validate = Object.prototype.hasOwnProperty.call(COMMANDS, type)
    ? COMMANDS[type]
    : null;

  if (!validate) return res.status(400).json({ error: `comando desconocido: ${type}` });

  let payload;
  try {
    payload = validate(req.body?.payload ?? {});
  } catch (err) {
    return res.status(400).json({ error: err.message });
  }

  const command = store.enqueue(type, payload);
  res.json({ ok: true, id: command.id });
});

/* Envío masivo: una llamada, un teleport por jugador seleccionado. */
app.post("/api/teleport/batch", requirePanelAuth, (req, res) => {
  const targets = Array.isArray(req.body?.targets) ? req.body.targets.slice(0, 50) : [];
  if (targets.length === 0) return res.status(400).json({ error: "sin jugadores" });

  const accepted = [];
  const rejected = [];

  for (const target of targets) {
    try {
      const payload = COMMANDS["teleport.send"]({
        ...target,
        placeId: req.body?.placeId,
        jobId: req.body?.jobId,
      });
      accepted.push(store.enqueue("teleport.send", payload).id);
    } catch (err) {
      rejected.push({ userId: target?.userId, error: err.message });
    }
  }

  if (accepted.length === 0) {
    return res.status(400).json({ error: rejected[0]?.error || "nada que enviar", rejected });
  }
  res.json({ ok: true, accepted, rejected });
});

/* ------------------------------------------------------------------ */
/* API del bridge (script de Roblox)                                   */
/* ------------------------------------------------------------------ */

app.post("/api/bridge/hello", requireBridgeAuth, (req, res) => {
  store.touchBridge(req.body ?? {});
  res.json({ ok: true, settings: store.currentSettings(), serverTime: Date.now() });
});

app.get("/api/bridge/poll", requireBridgeAuth, async (req, res) => {
  store.touchBridge({
    executor: req.query.executor,
    placeId: req.query.placeId,
    jobId: req.query.jobId,
    userId: req.query.userId,
    username: req.query.username,
  });

  const wait = Math.min(Math.max(Number(req.query.wait) || 15, 1), 25) * 1000;
  const commands = await store.waitForCommands(wait);
  res.json({ commands, serverTime: Date.now() });
});

app.post("/api/bridge/ack", requireBridgeAuth, (req, res) => {
  store.touchBridge();
  store.ack(Array.isArray(req.body?.results) ? req.body.results : []);
  res.json({ ok: true });
});

app.post("/api/bridge/players", requireBridgeAuth, (req, res) => {
  store.touchBridge();
  const list = store.setPlayers(req.body?.players);
  store.setGameState(req.body?.game);
  res.json({ ok: true, count: list.length });
});

app.post("/api/bridge/log", requireBridgeAuth, (req, res) => {
  store.touchBridge();
  const level = ["info", "ok", "warn", "error"].includes(req.body?.level)
    ? req.body.level
    : "info";
  store.log(level, String(req.body?.message ?? "").slice(0, 400), { from: "bridge" });
  res.json({ ok: true });
});

/* ------------------------------------------------------------------ */
/* entrega de los scripts Lua                                          */
/* ------------------------------------------------------------------ */

function publicBaseUrl(req) {
  if (process.env.PUBLIC_URL) return process.env.PUBLIC_URL.replace(/\/+$/, "");
  const host = req.headers["x-forwarded-host"] || req.headers.host || `localhost:${PORT}`;
  const proto = req.headers["x-forwarded-proto"] || (req.secure ? "https" : "http");
  return `${String(proto).split(",")[0]}://${String(host).split(",")[0]}`;
}

async function sendLua(res, file, replacements = {}) {
  let source = await readFile(path.join(ROOT, "roblox", file), "utf8");
  for (const [token, value] of Object.entries(replacements)) {
    source = source.split(token).join(value);
  }
  res.type("text/plain; charset=utf-8").send(source);
}

// El loader inyecta URL + key y carga el controlador. Es lo único que el
// usuario pega en el executor.
app.get("/script/loader.lua", (req, res) => {
  const base = publicBaseUrl(req);
  const key = String(req.query.key ?? "").replace(/["\\\n\r]/g, "");
  const control = req.query.mode === "control";
  const target = control ? "control.lua" : "controller.lua";

  res.type("text/plain; charset=utf-8").send(
    [
      `-- Manysteps · loader (${control ? "mando" : "bridge"})`,
      "getgenv().MANYSTEPS_CONFIG = {",
      `    url = "${base}",`,
      `    key = "${key}",`,
      "}",
      `loadstring(game:HttpGet("${base}/script/${target}"))()`,
      "",
    ].join("\n"),
  );
});

app.get("/script/remotes.lua", (_req, res, next) => {
  sendLua(res, "remotes.lua").catch(next);
});

app.get("/script/controller.lua", (req, res, next) => {
  sendLua(res, "controller.lua", { "@@REMOTES_URL@@": `${publicBaseUrl(req)}/script/remotes.lua` }).catch(
    next,
  );
});

// El mando: misma consola, pero dibujada dentro de Roblox.
app.get("/script/control.lua", (_req, res, next) => {
  sendLua(res, "control.lua").catch(next);
});

/* ------------------------------------------------------------------ */
/* estáticos                                                           */
/* ------------------------------------------------------------------ */

app.use(express.static(path.join(ROOT, "public"), { extensions: ["html"] }));
app.get("/healthz", (_req, res) => res.json({ ok: true, uptime: process.uptime() }));
app.use((_req, res) => res.status(404).json({ error: "not found" }));

/* ------------------------------------------------------------------ */
/* websocket                                                           */
/* ------------------------------------------------------------------ */

const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  if (!req.url?.startsWith("/ws")) return socket.destroy();
  if (!isValidSession(sessionFromRequest(req))) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

wss.on("connection", (ws) => {
  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
  });
  send(ws, { type: "snapshot", data: store.snapshot() });
  send(ws, { type: "log:bulk", data: store.recentLog() });
});

function send(ws, message) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message));
}

store.subscribe((event) => {
  const message = JSON.stringify(event);
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN) ws.send(message);
  }
});

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 30_000).unref();

setInterval(() => store.sweepBridge(), 5_000).unref();

/* ------------------------------------------------------------------ */

server.listen(PORT, () => {
  console.log(`\n  Manysteps control  ·  http://localhost:${PORT}`);
  if (generatedPassword) {
    console.log(`  PANEL_PASSWORD no definida — usando temporal: ${PANEL_PASSWORD}`);
  }
  if (generatedBridgeKey) {
    console.log(`  BRIDGE_KEY no definida — usando temporal: ${BRIDGE_KEY}`);
  }
  console.log("");
  store.log("info", "Servidor iniciado");
});

import { randomUUID } from "node:crypto";

const MAX_LOG = 250;
const MAX_QUEUE = 200;
// Holgado a propósito: el long-poll ya tarda hasta 15 s en volver, así
// que un margen justo daría desconexiones falsas — y una desconexión
// cancela lo que haya en cola.
const BRIDGE_TIMEOUT_MS = 28_000;

/**
 * Estado central del panel. Vive en memoria: Railway reinicia el contenedor
 * cuando redeploya, y todo lo que importa (jobId / placeId) se vuelve a
 * empujar al juego con un comando, así que no hace falta base de datos.
 */
const state = {
  bridge: {
    online: false,
    lastSeen: 0,
    executor: null,
    placeId: null,
    jobId: null,
    userId: null,
    username: null,
  },
  settings: {
    // Lo último que el panel mandó guardar en el juego.
    placeId: process.env.DEFAULT_PLACE_ID || "96342491571673",
    jobId: "",
    savedPlaceIdAt: 0,
    savedJobIdAt: 0,
  },
  time: {
    // "paused" | "running" | "unknown"
    status: "unknown",
    changedAt: 0,
  },
  players: {
    list: [],
    updatedAt: 0,
  },
  // Lo que el juego tiene de verdad, leído por el bridge. El cuadro del
  // panel manda sobre lo guardado: es lo que usa el botón Teleport.
  game: {
    panelJobId: null,
    savedJobId: null,
    savedPlaceId: null,
    rememberJobId: null,
    rememberPlaceId: null,
    updatedAt: 0,
  },
};

/** @type {Array<object>} comandos esperando a que el bridge los recoja */
const queue = [];
/** @type {Map<string, object>} comandos entregados, esperando ack */
const inflight = new Map();
/** @type {Array<object>} historial reciente (los últimos primero) */
const history = [];
/** @type {Array<object>} log de la consola (los últimos primero) */
const logLines = [];

const listeners = new Set();
/** @type {Array<{resolve: Function, timer: NodeJS.Timeout}>} long-polls abiertos */
const pollWaiters = [];

/* ------------------------------------------------------------------ */
/* eventos                                                             */
/* ------------------------------------------------------------------ */

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function emit(event) {
  for (const fn of listeners) {
    try {
      fn(event);
    } catch {
      /* un suscriptor roto no puede tumbar al resto */
    }
  }
}

function emitSnapshot() {
  emit({ type: "snapshot", data: snapshot() });
}

/* ------------------------------------------------------------------ */
/* log                                                                 */
/* ------------------------------------------------------------------ */

export function log(level, message, meta) {
  const entry = {
    id: randomUUID(),
    at: Date.now(),
    level, // "info" | "ok" | "warn" | "error" | "cmd"
    message: String(message),
    meta: meta ?? null,
  };
  logLines.unshift(entry);
  if (logLines.length > MAX_LOG) logLines.length = MAX_LOG;
  emit({ type: "log", data: entry });
  return entry;
}

/* ------------------------------------------------------------------ */
/* bridge                                                              */
/* ------------------------------------------------------------------ */

export function touchBridge(info = {}) {
  const wasOffline = !state.bridge.online;
  state.bridge.online = true;
  state.bridge.lastSeen = Date.now();
  for (const key of ["executor", "placeId", "jobId", "userId", "username"]) {
    if (info[key] !== undefined && info[key] !== null && info[key] !== "") {
      state.bridge[key] = info[key];
    }
  }
  if (wasOffline) {
    log("ok", `Bridge conectado${info.username ? ` — ${info.username}` : ""}`);
  }
  emitSnapshot();
}

/** Marca el bridge como caído si lleva demasiado sin dar señales. */
export function sweepBridge() {
  if (!state.bridge.online) return;
  if (Date.now() - state.bridge.lastSeen <= BRIDGE_TIMEOUT_MS) return;
  state.bridge.online = false;
  log("warn", "Bridge desconectado (sin heartbeat)");
  abandonPending("el bridge se desconectó");
  emitSnapshot();
}

/**
 * Tira lo que quedó a medias. Un teleport que se ejecuta tres minutos
 * tarde, cuando el bridge vuelve, no es lo que nadie pidió.
 */
function abandonPending(reason) {
  const stranded = [...queue.splice(0, queue.length), ...inflight.values()];
  inflight.clear();

  for (const command of stranded) {
    command.status = "error";
    command.error = reason;
    command.doneAt = Date.now();
  }

  if (stranded.length > 0) {
    log("warn", `${stranded.length} comando(s) cancelado(s): ${reason}`);
  }
}

/* ------------------------------------------------------------------ */
/* comandos                                                            */
/* ------------------------------------------------------------------ */

export function enqueue(type, payload = {}, source = "panel") {
  const command = {
    id: randomUUID(),
    type,
    payload,
    source,
    createdAt: Date.now(),
    sentAt: 0,
    doneAt: 0,
    status: "queued", // queued | sent | ok | error
    error: null,
  };

  queue.push(command);
  while (queue.length > MAX_QUEUE) {
    const dropped = queue.shift();
    log("warn", `Cola llena, se descartó ${dropped.type}`);
  }

  pushHistory(command);
  log("cmd", describe(command), { commandId: command.id });
  emitSnapshot();
  releaseWaiters();
  return command;
}

/** Saca todo lo pendiente y lo pasa a "en vuelo". */
export function drainQueue() {
  if (queue.length === 0) return [];
  const batch = queue.splice(0, queue.length);
  const now = Date.now();
  for (const command of batch) {
    command.status = "sent";
    command.sentAt = now;
    inflight.set(command.id, command);
  }
  emitSnapshot();
  return batch.map((c) => ({ id: c.id, type: c.type, payload: c.payload }));
}

export function ack(results = []) {
  let changed = false;

  for (const result of results) {
    const command = inflight.get(result.id);
    if (!command) continue;
    inflight.delete(result.id);

    command.status = result.ok ? "ok" : "error";
    command.error = result.ok ? null : String(result.error || "error desconocido");
    command.doneAt = Date.now();
    changed = true;

    if (result.ok) {
      applySideEffects(command, result.data);
      log("ok", `${describe(command)} — hecho`, { commandId: command.id });
    } else {
      log("error", `${describe(command)} — falló: ${command.error}`, {
        commandId: command.id,
      });
    }
  }

  if (changed) emitSnapshot();
}

/** Refleja en el estado del panel lo que el comando acaba de cambiar en el juego. */
function applySideEffects(command, data) {
  switch (command.type) {
    case "time.pause":
      state.time = { status: "paused", changedAt: Date.now() };
      break;
    case "time.resume":
      state.time = { status: "running", changedAt: Date.now() };
      break;
    case "settings.jobId":
      state.settings.jobId = String(command.payload.jobId ?? "");
      state.settings.savedJobIdAt = Date.now();
      break;
    case "settings.placeId":
      state.settings.placeId = String(command.payload.placeId ?? "");
      state.settings.savedPlaceIdAt = Date.now();
      break;
    case "players.refresh":
      if (Array.isArray(data?.players)) setPlayers(data.players);
      break;
    default:
      break;
  }
}

function pushHistory(command) {
  history.unshift(command);
  if (history.length > 60) history.length = 60;
}

export function describe(command) {
  const p = command.payload || {};
  switch (command.type) {
    case "time.pause":
      return "Pausar tiempo";
    case "time.resume":
      return "Reanudar tiempo";
    case "settings.jobId":
      return `Guardar Job ID → ${p.jobId || "(vacío)"}`;
    case "settings.placeId":
      return `Guardar Place ID → ${p.placeId || "(vacío)"}`;
    case "players.refresh":
      return "Refrescar lista de jugadores";
    case "teleport.send":
      return `Teleport ${p.username || p.userId} → ${p.placeId} / ${
        p.jobId ? p.jobId.slice(0, 8) + "…" : "(sin job)"
      }`;
    default:
      return command.type;
  }
}

/* ------------------------------------------------------------------ */
/* long-poll                                                           */
/* ------------------------------------------------------------------ */

/**
 * Espera hasta `waitMs` a que haya trabajo. Devuelve los comandos listos,
 * o un array vacío si se agotó el tiempo (el bridge vuelve a llamar).
 */
export function waitForCommands(waitMs) {
  const ready = drainQueue();
  if (ready.length > 0) return Promise.resolve(ready);

  return new Promise((resolve) => {
    const waiter = { resolve: null, timer: null };
    const finish = () => {
      clearTimeout(waiter.timer);
      const index = pollWaiters.indexOf(waiter);
      if (index !== -1) pollWaiters.splice(index, 1);
      resolve(drainQueue());
    };
    waiter.resolve = finish;
    waiter.timer = setTimeout(finish, waitMs);
    pollWaiters.push(waiter);
  });
}

function releaseWaiters() {
  while (pollWaiters.length > 0) {
    pollWaiters.pop().resolve();
  }
}

/* ------------------------------------------------------------------ */
/* jugadores                                                           */
/* ------------------------------------------------------------------ */

export function setPlayers(rawList) {
  const seen = new Set();
  const list = [];

  for (const raw of Array.isArray(rawList) ? rawList : []) {
    const userId = String(raw?.userId ?? raw?.UserId ?? raw?.id ?? "").trim();
    if (!userId || seen.has(userId)) continue;
    seen.add(userId);
    list.push({
      userId,
      username: String(raw?.username ?? raw?.Name ?? raw?.name ?? "").trim() || `#${userId}`,
      displayName:
        String(raw?.displayName ?? raw?.DisplayName ?? "").trim() ||
        String(raw?.username ?? raw?.Name ?? "").trim() ||
        `#${userId}`,
    });
  }

  list.sort((a, b) => a.displayName.localeCompare(b.displayName));
  state.players = { list, updatedAt: Date.now() };
  emitSnapshot();
  return list;
}

/* ------------------------------------------------------------------ */
/* snapshot                                                            */
/* ------------------------------------------------------------------ */

export function setGameState(raw) {
  if (!raw || typeof raw !== "object") return;

  const read = (value) => (value === undefined || value === null ? null : String(value));

  state.game = {
    panelJobId: read(raw.panelJobId),
    savedJobId: read(raw.savedJobId),
    savedPlaceId: read(raw.savedPlaceId),
    rememberJobId: raw.rememberJobId === undefined ? null : raw.rememberJobId === true,
    rememberPlaceId: raw.rememberPlaceId === undefined ? null : raw.rememberPlaceId === true,
    updatedAt: Date.now(),
  };
  emitSnapshot();
}

export function snapshot() {
  return {
    serverTime: Date.now(),
    bridge: { ...state.bridge },
    settings: { ...state.settings },
    time: { ...state.time },
    players: { ...state.players },
    game: { ...state.game },
    pending: queue.length + inflight.size,
    history: history.slice(0, 20).map((c) => ({
      id: c.id,
      type: c.type,
      label: describe(c),
      status: c.status,
      createdAt: c.createdAt,
      error: c.error,
    })),
  };
}

export function recentLog() {
  return logLines.slice(0, 80);
}

export function currentSettings() {
  return { ...state.settings };
}

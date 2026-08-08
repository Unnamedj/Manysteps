import { randomUUID } from "node:crypto";

const MAX_LOG = 250;
const MAX_QUEUE = 200;
// Holgado a propósito: el long-poll ya tarda hasta 15 s en volver, así
// que un margen justo daría desconexiones falsas — y una desconexión
// cancela lo que haya en cola.
const BRIDGE_TIMEOUT_MS = 28_000;
// Cuánto se queda un bridge caído en la lista antes de desaparecer.
const BRIDGE_FORGET_MS = 10 * 60_000;

const ACCESS_STATES = new Set(["blacklisted", "permanent", "paused", "active", "locked"]);

/** Los destinos que ofrece el propio panel del juego. */
export const PLACES = [
  { label: "SAB New Player", placeId: "96342491571673" },
  { label: "SAB Normal", placeId: "109983668079237" },
];

/**
 * Estado central del panel. Vive en memoria: Railway reinicia el contenedor
 * cuando redeploya, y todo lo que importa (jobId / placeId) se vuelve a
 * empujar al juego con un comando, así que no hace falta base de datos.
 */
const state = {
  settings: {
    // El destino al que se manda gente. Es común a todos los bridges:
    // la gracia es que todos empujen al mismo sitio.
    placeId: process.env.DEFAULT_PLACE_ID || "96342491571673",
    jobId: "",
    savedPlaceIdAt: 0,
    savedJobIdAt: 0,
  },
};

/**
 * Un bridge por cuenta conectada. Cada uno lleva su propia cola: las
 * órdenes de uno no pueden acabar ejecutándose en otro.
 *
 * @type {Map<string, object>}
 */
const bridges = new Map();

/** @type {Array<object>} historial reciente (los últimos primero) */
const history = [];
/** @type {Array<object>} log de la consola (los últimos primero) */
const logLines = [];

const listeners = new Set();

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
    bridge: meta?.bridgeName ?? null,
    meta: meta ?? null,
  };
  logLines.unshift(entry);
  if (logLines.length > MAX_LOG) logLines.length = MAX_LOG;
  emit({ type: "log", data: entry });
  return entry;
}

/* ------------------------------------------------------------------ */
/* bridges                                                             */
/* ------------------------------------------------------------------ */

function blankBridge(id) {
  return {
    id,
    userId: null,
    username: null,
    executor: null,
    placeId: null,
    jobId: null,
    online: false,
    lastSeen: 0,
    firstSeen: Date.now(),
    // Lo que este bridge ve en su propia partida.
    players: [],
    playersAt: 0,
    game: {
      panelJobId: null,
      savedJobId: null,
      savedPlaceId: null,
      updatedAt: 0,
    },
    access: { status: null, remainingSeconds: 0, readAt: 0 },
    queue: [],
    inflight: new Map(),
    waiters: [],
  };
}

export function bridgeName(bridge) {
  if (!bridge) return "?";
  return bridge.username || (bridge.userId ? `#${bridge.userId}` : bridge.id.slice(0, 6));
}

/**
 * Registra o refresca un bridge. La identidad es el userId de la cuenta
 * que lo ejecuta: si esa cuenta reejecuta el script, sigue siendo el
 * mismo bridge en vez de dejar un fantasma en la lista.
 */
export function touchBridge(id, info = {}) {
  const key = String(id || info.userId || "").trim();
  if (!key) return null;

  let bridge = bridges.get(key);
  if (!bridge) {
    bridge = blankBridge(key);
    bridges.set(key, bridge);
  }

  const wasOffline = !bridge.online;
  bridge.online = true;
  bridge.lastSeen = Date.now();

  for (const field of ["executor", "placeId", "jobId", "userId", "username"]) {
    const value = info[field];
    if (value !== undefined && value !== null && value !== "") {
      bridge[field] = String(value);
    }
  }
  if (!bridge.userId) bridge.userId = key;

  if (wasOffline) {
    log("ok", `Bridge conectado — ${bridgeName(bridge)}`, { bridgeName: bridgeName(bridge) });
  }
  emitSnapshot();
  return bridge;
}

export function getBridge(id) {
  return bridges.get(String(id || "")) || null;
}

export function onlineBridges() {
  return [...bridges.values()].filter((b) => b.online);
}

/** Marca como caídos los bridges que llevan demasiado sin dar señales. */
export function sweepBridges() {
  const now = Date.now();
  let changed = false;

  for (const [id, bridge] of bridges) {
    if (bridge.online && now - bridge.lastSeen > BRIDGE_TIMEOUT_MS) {
      bridge.online = false;
      log("warn", `Bridge desconectado — ${bridgeName(bridge)}`, {
        bridgeName: bridgeName(bridge),
      });
      abandonPending(bridge, "el bridge se desconectó");
      changed = true;
    }

    // Los caídos se olvidan pasado un rato, para que la lista no crezca
    // sin fin con sesiones viejas.
    if (!bridge.online && now - bridge.lastSeen > BRIDGE_FORGET_MS) {
      bridges.delete(id);
      changed = true;
    }
  }

  if (changed) emitSnapshot();
}

/**
 * Tira lo que quedó a medias. Un teleport que se ejecuta tres minutos
 * tarde, cuando el bridge vuelve, no es lo que nadie pidió.
 */
function abandonPending(bridge, reason) {
  const stranded = [...bridge.queue.splice(0, bridge.queue.length), ...bridge.inflight.values()];
  bridge.inflight.clear();

  for (const command of stranded) {
    command.status = "error";
    command.error = reason;
    command.doneAt = Date.now();
  }

  if (stranded.length > 0) {
    log("warn", `${stranded.length} comando(s) cancelado(s): ${reason}`, {
      bridgeName: bridgeName(bridge),
    });
  }
}

/* ------------------------------------------------------------------ */
/* comandos                                                            */
/* ------------------------------------------------------------------ */

/**
 * Encola una orden. `target` es el id de un bridge o "all" para que la
 * reciban todos los conectados (una copia por cada uno: cada bridge
 * ejecuta el remote en su propia partida).
 */
export function enqueue(type, payload = {}, target = "all") {
  const targets =
    target === "all" ? onlineBridges() : [getBridge(target)].filter((b) => b && b.online);

  if (targets.length === 0) {
    return { accepted: [], error: "no hay ningún bridge conectado" };
  }

  const accepted = [];
  for (const bridge of targets) {
    const command = {
      id: randomUUID(),
      bridgeId: bridge.id,
      bridgeName: bridgeName(bridge),
      type,
      payload,
      createdAt: Date.now(),
      sentAt: 0,
      doneAt: 0,
      status: "queued", // queued | sent | ok | error
      error: null,
    };

    bridge.queue.push(command);
    while (bridge.queue.length > MAX_QUEUE) {
      const dropped = bridge.queue.shift();
      log("warn", `Cola llena, se descartó ${dropped.type}`, { bridgeName: bridge.username });
    }

    pushHistory(command);
    accepted.push(command.id);
    releaseWaiters(bridge);
  }

  log("cmd", `${describe({ type, payload })} · ${targetLabel(target, targets)}`);
  emitSnapshot();
  return { accepted };
}

function targetLabel(target, targets) {
  if (target !== "all") return bridgeName(targets[0]);
  return targets.length === 1 ? bridgeName(targets[0]) : `${targets.length} bridges`;
}

/** Saca todo lo pendiente de un bridge y lo pasa a "en vuelo". */
function drainQueue(bridge) {
  if (bridge.queue.length === 0) return [];
  const batch = bridge.queue.splice(0, bridge.queue.length);
  const now = Date.now();

  for (const command of batch) {
    command.status = "sent";
    command.sentAt = now;
    bridge.inflight.set(command.id, command);
  }
  emitSnapshot();
  return batch.map((c) => ({ id: c.id, type: c.type, payload: c.payload }));
}

export function ack(bridgeId, results = []) {
  const bridge = getBridge(bridgeId);
  if (!bridge) return;

  let changed = false;

  for (const result of results) {
    const command = bridge.inflight.get(result.id);
    if (!command) continue;
    bridge.inflight.delete(result.id);

    command.status = result.ok ? "ok" : "error";
    command.error = result.ok ? null : String(result.error || "error desconocido");
    command.doneAt = Date.now();
    changed = true;

    const where = bridgeName(bridge);
    if (result.ok) {
      applySideEffects(command, result.data);
      log("ok", `${describe(command)} — hecho · ${where}`, { bridgeName: where });
    } else {
      log("error", `${describe(command)} — falló: ${command.error} · ${where}`, {
        bridgeName: where,
      });
    }
  }

  if (changed) emitSnapshot();
}

/** Refleja en el estado del panel lo que el comando acaba de cambiar. */
function applySideEffects(command, data) {
  switch (command.type) {
    case "settings.jobId":
      state.settings.jobId = String(command.payload.jobId ?? "");
      state.settings.savedJobIdAt = Date.now();
      break;
    case "settings.placeId":
      state.settings.placeId = String(command.payload.placeId ?? "");
      state.settings.savedPlaceIdAt = Date.now();
      break;
    case "players.refresh": {
      const bridge = getBridge(command.bridgeId);
      if (bridge && Array.isArray(data?.players)) setPlayers(bridge.id, data.players);
      break;
    }
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
 * Espera hasta `waitMs` a que haya trabajo para ese bridge. Devuelve los
 * comandos listos, o vacío si se agotó el tiempo (el bridge repite).
 */
export function waitForCommands(bridgeId, waitMs) {
  const bridge = getBridge(bridgeId);
  if (!bridge) return Promise.resolve([]);

  const ready = drainQueue(bridge);
  if (ready.length > 0) return Promise.resolve(ready);

  return new Promise((resolve) => {
    const waiter = { resolve: null, timer: null };
    const finish = () => {
      clearTimeout(waiter.timer);
      const index = bridge.waiters.indexOf(waiter);
      if (index !== -1) bridge.waiters.splice(index, 1);
      resolve(drainQueue(bridge));
    };
    waiter.resolve = finish;
    waiter.timer = setTimeout(finish, waitMs);
    bridge.waiters.push(waiter);
  });
}

function releaseWaiters(bridge) {
  while (bridge.waiters.length > 0) {
    bridge.waiters.pop().resolve();
  }
}

/* ------------------------------------------------------------------ */
/* jugadores                                                           */
/* ------------------------------------------------------------------ */

export function setPlayers(bridgeId, rawList) {
  const bridge = getBridge(bridgeId);
  if (!bridge) return [];

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

  bridge.players = list;
  bridge.playersAt = Date.now();
  emitSnapshot();
  return list;
}

/**
 * Lista única para el panel: junta lo que ve cada bridge, quita a las
 * propias cuentas que están haciendo de bridge — no tiene sentido
 * ofrecerte teletransportar a tus propios operadores — y anota qué
 * bridge puede alcanzar a cada jugador.
 */
export function aggregatedPlayers() {
  const operators = new Set();
  for (const bridge of bridges.values()) {
    if (bridge.userId) operators.add(String(bridge.userId));
  }

  const byUserId = new Map();

  for (const bridge of onlineBridges()) {
    for (const player of bridge.players) {
      if (operators.has(player.userId)) continue;

      const existing = byUserId.get(player.userId);
      if (existing) {
        existing.bridgeCount += 1;
        continue;
      }

      byUserId.set(player.userId, {
        ...player,
        bridgeId: bridge.id,
        bridgeName: bridgeName(bridge),
        bridgeCount: 1,
      });
    }
  }

  return [...byUserId.values()].sort((a, b) => a.displayName.localeCompare(b.displayName));
}

/* ------------------------------------------------------------------ */
/* estado del juego por bridge                                         */
/* ------------------------------------------------------------------ */

export function setGameState(bridgeId, raw) {
  const bridge = getBridge(bridgeId);
  if (!bridge || !raw || typeof raw !== "object") return;

  const read = (value) => (value === undefined || value === null ? null : String(value));

  bridge.game = {
    panelJobId: read(raw.panelJobId),
    savedJobId: read(raw.savedJobId),
    savedPlaceId: read(raw.savedPlaceId),
    updatedAt: Date.now(),
  };

  const access = raw.access;
  if (access && ACCESS_STATES.has(access.status)) {
    bridge.access = {
      status: access.status,
      remainingSeconds: Math.max(0, Number(access.remainingSeconds) || 0),
      readAt: Date.now(),
    };
  }

  emitSnapshot();
}

/* ------------------------------------------------------------------ */
/* snapshot                                                            */
/* ------------------------------------------------------------------ */

function publicBridge(bridge) {
  return {
    id: bridge.id,
    userId: bridge.userId,
    username: bridgeName(bridge),
    executor: bridge.executor,
    placeId: bridge.placeId,
    jobId: bridge.jobId,
    online: bridge.online,
    lastSeen: bridge.lastSeen,
    panelJobId: bridge.game.panelJobId,
    access: { ...bridge.access },
    playerCount: bridge.players.length,
    pending: bridge.queue.length + bridge.inflight.size,
  };
}

export function snapshot() {
  const list = [...bridges.values()].sort((a, b) => {
    if (a.online !== b.online) return a.online ? -1 : 1;
    return bridgeName(a).localeCompare(bridgeName(b));
  });

  const players = aggregatedPlayers();
  let pending = 0;
  for (const bridge of bridges.values()) {
    pending += bridge.queue.length + bridge.inflight.size;
  }

  return {
    serverTime: Date.now(),
    bridges: list.map(publicBridge),
    online: list.filter((b) => b.online).length,
    settings: { ...state.settings },
    places: PLACES,
    players: { list: players, updatedAt: Date.now() },
    pending,
    history: history.slice(0, 20).map((c) => ({
      id: c.id,
      type: c.type,
      label: describe(c),
      bridgeName: c.bridgeName,
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

/* ==================================================================
   Manysteps · cliente de la consola
   ================================================================== */

const $ = (id) => document.getElementById(id);

const el = {
  gate: $("gate"),
  app: $("app"),
  loginForm: $("loginForm"),
  password: $("password"),
  loginBtn: $("loginBtn"),
  loginError: $("loginError"),

  bridgeChip: $("bridgeChip"),
  bridgeValue: $("bridgeValue"),
  clockChip: $("clockChip"),
  clockValue: $("clockValue"),
  queueValue: $("queueValue"),

  placeForm: $("placeForm"),
  placeInput: $("placeInput"),
  placeHint: $("placeHint"),
  jobForm: $("jobForm"),
  jobInput: $("jobInput"),
  jobHint: $("jobHint"),

  metaUser: $("metaUser"),
  metaExecutor: $("metaExecutor"),
  metaPlace: $("metaPlace"),
  metaJob: $("metaJob"),
  metaPing: $("metaPing"),

  roster: $("roster"),
  rosterCount: $("rosterCount"),
  search: $("search"),
  selectAllBtn: $("selectAllBtn"),
  clearSelBtn: $("clearSelBtn"),
  selCount: $("selCount"),
  destSummary: $("destSummary"),
  sendBtn: $("sendBtn"),
  refreshBtn: $("refreshBtn"),

  log: $("log"),
  toasts: $("toasts"),
  loaderModal: $("loaderModal"),
  loaderCode: $("loaderCode"),
  linkBtn: $("linkBtn"),
  copyLoader: $("copyLoader"),
  closeLoader: $("closeLoader"),
  logoutBtn: $("logoutBtn"),
};

const selected = new Set();
let snapshot = null;
let rosterSignature = "";
let socket = null;
let reconnectDelay = 1000;

/* ------------------------------------------------------------------ */
/* utilidades                                                          */
/* ------------------------------------------------------------------ */

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  let data = {};
  try {
    data = await response.json();
  } catch {
    /* respuestas vacías */
  }

  if (!response.ok) {
    const error = new Error(data.error || `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function toast(message, kind = "info") {
  const node = document.createElement("div");
  node.className = "toast";
  node.dataset.kind = kind;
  node.textContent = message;
  el.toasts.append(node);
  setTimeout(() => {
    node.classList.add("out");
    setTimeout(() => node.remove(), 220);
  }, 3400);
}

function clock(timestamp) {
  return new Date(timestamp).toLocaleTimeString("es-ES", { hour12: false });
}

function ago(timestamp) {
  if (!timestamp) return "—";
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 5) return "ahora";
  if (seconds < 60) return `hace ${seconds}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `hace ${minutes}m`;
  return `hace ${Math.round(minutes / 60)}h`;
}

/* ------------------------------------------------------------------ */
/* acceso                                                              */
/* ------------------------------------------------------------------ */

el.loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  el.loginError.hidden = true;
  el.loginBtn.disabled = true;

  try {
    await api("/api/auth/login", { method: "POST", body: { password: el.password.value } });
    el.password.value = "";
    await enterConsole();
  } catch (error) {
    el.loginError.textContent = error.message;
    el.loginError.hidden = false;
  } finally {
    el.loginBtn.disabled = false;
  }
});

el.logoutBtn.addEventListener("click", async () => {
  await api("/api/auth/logout", { method: "POST" }).catch(() => {});
  socket?.close();
  location.reload();
});

async function enterConsole() {
  el.gate.hidden = true;
  el.app.hidden = false;

  const state = await api("/api/state");
  applySnapshot(state);
  renderLogBulk(state.log || []);

  api("/api/bootstrap")
    .then((info) => {
      el.loaderCode.textContent = info.loader;
    })
    .catch(() => {});

  connectSocket();
}

/* ------------------------------------------------------------------ */
/* websocket                                                           */
/* ------------------------------------------------------------------ */

function connectSocket() {
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  socket = new WebSocket(`${protocol}://${location.host}/ws`);

  socket.addEventListener("open", () => {
    reconnectDelay = 1000;
  });

  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }

    if (message.type === "snapshot") applySnapshot(message.data);
    else if (message.type === "log") appendLog(message.data);
    else if (message.type === "log:bulk") renderLogBulk(message.data);
  });

  socket.addEventListener("close", () => {
    setTimeout(connectSocket, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.7, 15000);
  });
}

/* ------------------------------------------------------------------ */
/* render                                                              */
/* ------------------------------------------------------------------ */

function applySnapshot(state) {
  snapshot = state;

  // bridge
  const online = state.bridge.online;
  el.bridgeChip.dataset.state = online ? "on" : "off";
  el.bridgeValue.textContent = online
    ? state.bridge.username || "en línea"
    : "desconectado";

  // reloj del juego
  const time = state.time.status;
  el.clockChip.dataset.state = time === "unknown" ? "unknown" : time;
  el.clockValue.textContent =
    time === "paused" ? "pausado" : time === "running" ? "corriendo" : "sin datos";

  document
    .querySelector('.bigbtn[data-cmd="time.pause"]')
    ?.setAttribute("data-active", time === "paused" ? "1" : "0");
  document
    .querySelector('.bigbtn[data-cmd="time.resume"]')
    ?.setAttribute("data-active", time === "running" ? "1" : "0");

  el.queueValue.textContent = String(state.pending ?? 0);

  // ajustes guardados
  if (!el.placeInput.dataset.dirty) el.placeInput.value = state.settings.placeId || "";
  if (!el.jobInput.dataset.dirty) el.jobInput.value = state.settings.jobId || "";

  el.placeHint.textContent = state.settings.savedPlaceIdAt
    ? `guardado ${ago(state.settings.savedPlaceIdAt)}`
    : "sin guardar todavía";
  el.placeHint.dataset.ok = state.settings.savedPlaceIdAt ? "1" : "0";

  el.jobHint.textContent = state.settings.savedJobIdAt
    ? `guardado ${ago(state.settings.savedJobIdAt)}`
    : "sin guardar todavía";
  el.jobHint.dataset.ok = state.settings.savedJobIdAt ? "1" : "0";

  // sesión
  el.metaUser.textContent = state.bridge.username || "—";
  el.metaExecutor.textContent = state.bridge.executor || "—";
  el.metaPlace.textContent = state.bridge.placeId || "—";
  el.metaJob.textContent = state.bridge.jobId || "—";
  el.metaJob.title = state.bridge.jobId || "";
  el.metaPing.textContent = ago(state.bridge.lastSeen);

  renderRoster();
  renderDestination();
}

function renderRoster() {
  const list = snapshot?.players?.list ?? [];
  const query = el.search.value.trim().toLowerCase();
  const visible = query
    ? list.filter(
        (p) =>
          p.username.toLowerCase().includes(query) ||
          p.displayName.toLowerCase().includes(query) ||
          p.userId.includes(query),
      )
    : list;

  el.rosterCount.textContent = String(list.length);

  // Solo reconstruimos el DOM si cambió el conjunto visible.
  const signature = visible.map((p) => p.userId).join(",");
  if (signature !== rosterSignature) {
    rosterSignature = signature;
    el.roster.replaceChildren();

    if (visible.length === 0) {
      const empty = document.createElement("div");
      empty.className = "roster__empty";
      empty.textContent = list.length
        ? "ningún jugador coincide con la búsqueda"
        : snapshot?.bridge?.online
          ? "esperando la lista de GetTeleportCandidates…"
          : "conecta el bridge para ver jugadores";
      el.roster.append(empty);
    } else {
      for (const player of visible) el.roster.append(rosterItem(player));
    }
  }

  for (const node of el.roster.children) {
    if (node.dataset.userId) {
      node.dataset.selected = selected.has(node.dataset.userId) ? "1" : "0";
    }
  }

  // Limpia selecciones de jugadores que ya no están.
  const alive = new Set(list.map((p) => p.userId));
  for (const id of [...selected]) if (!alive.has(id)) selected.delete(id);

  el.selCount.textContent = `${selected.size} seleccionado${selected.size === 1 ? "" : "s"}`;
  el.sendBtn.disabled = selected.size === 0 || !snapshot?.bridge?.online;
}

function rosterItem(player) {
  const item = document.createElement("button");
  item.type = "button";
  item.className = "roster__item";
  item.dataset.userId = player.userId;
  item.setAttribute("role", "listitem");

  const tick = document.createElement("span");
  tick.className = "tick";
  tick.innerHTML =
    '<svg viewBox="0 0 24 24" width="11" height="11"><path d="m5 12.5 4.5 4.5L19 7" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  // Iniciales de base; el headshot se pinta encima si Roblox responde.
  const avatar = document.createElement("span");
  avatar.className = "avatar";
  avatar.textContent = (player.displayName || "?").slice(0, 2).toUpperCase();

  const photo = document.createElement("img");
  photo.alt = "";
  photo.loading = "lazy";
  photo.src = `https://www.roblox.com/headshot-thumbnail/image?userId=${encodeURIComponent(
    player.userId,
  )}&width=150&height=150&format=png`;
  photo.addEventListener("load", () => photo.classList.add("loaded"));
  photo.addEventListener("error", () => photo.remove());
  avatar.append(photo);

  const who = document.createElement("span");
  who.className = "roster__who";
  const name = document.createElement("b");
  name.textContent = player.displayName;
  const handle = document.createElement("span");
  handle.textContent = `@${player.username} · ${player.userId}`;
  who.append(name, handle);

  item.append(tick, avatar, who);
  item.addEventListener("click", () => {
    if (selected.has(player.userId)) selected.delete(player.userId);
    else selected.add(player.userId);
    renderRoster();
    renderDestination();
  });

  return item;
}

function renderDestination() {
  const placeId = el.placeInput.value.trim() || snapshot?.settings?.placeId || "";
  const jobId = el.jobInput.value.trim() || snapshot?.settings?.jobId || "";

  el.destSummary.textContent = jobId
    ? `→ ${placeId || "?"} · ${jobId.slice(0, 13)}${jobId.length > 13 ? "…" : ""}`
    : "falta el Job ID";
  el.destSummary.title = jobId ? `${placeId} / ${jobId}` : "";
}

function renderLogBulk(entries) {
  el.log.replaceChildren();
  for (const entry of entries) el.log.append(logLine(entry));
}

function appendLog(entry) {
  el.log.prepend(logLine(entry)); // column-reverse: prepend = abajo del todo
  while (el.log.childElementCount > 200) el.log.lastElementChild.remove();
}

function logLine(entry) {
  const line = document.createElement("div");
  line.className = "line";
  line.dataset.level = entry.level;

  const time = document.createElement("time");
  time.textContent = clock(entry.at);

  const dot = document.createElement("i");
  const text = document.createElement("span");
  text.textContent = entry.message;

  line.append(time, dot, text);
  return line;
}

/* ------------------------------------------------------------------ */
/* acciones                                                            */
/* ------------------------------------------------------------------ */

async function send(type, payload = {}) {
  try {
    await api("/api/command", { method: "POST", body: { type, payload } });
  } catch (error) {
    toast(error.message, "error");
    throw error;
  }
}

for (const button of document.querySelectorAll(".bigbtn[data-cmd]")) {
  button.addEventListener("click", () => {
    if (!snapshot?.bridge?.online) {
      toast("El bridge no está conectado", "error");
      return;
    }
    send(button.dataset.cmd).catch(() => {});
  });
}

el.placeForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await send("settings.placeId", { placeId: el.placeInput.value.trim() }).catch(() => {});
  delete el.placeInput.dataset.dirty;
  renderDestination();
});

el.jobForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await send("settings.jobId", { jobId: el.jobInput.value.trim() }).catch(() => {});
  delete el.jobInput.dataset.dirty;
  renderDestination();
});

for (const input of [el.placeInput, el.jobInput]) {
  input.addEventListener("input", () => {
    input.dataset.dirty = "1";
    renderDestination();
  });
}

el.search.addEventListener("input", renderRoster);

el.selectAllBtn.addEventListener("click", () => {
  for (const node of el.roster.children) {
    if (node.dataset.userId) selected.add(node.dataset.userId);
  }
  renderRoster();
});

el.clearSelBtn.addEventListener("click", () => {
  selected.clear();
  renderRoster();
});

el.refreshBtn.addEventListener("click", async () => {
  el.refreshBtn.dataset.busy = "1";
  try {
    await send("players.refresh");
  } finally {
    setTimeout(() => delete el.refreshBtn.dataset.busy, 900);
  }
});

el.sendBtn.addEventListener("click", async () => {
  const list = snapshot?.players?.list ?? [];
  const targets = list
    .filter((p) => selected.has(p.userId))
    .map((p) => ({ userId: p.userId, username: p.username }));

  if (targets.length === 0) return;

  el.sendBtn.disabled = true;
  try {
    const result = await api("/api/teleport/batch", {
      method: "POST",
      body: {
        targets,
        placeId: el.placeInput.value.trim() || undefined,
        jobId: el.jobInput.value.trim() || undefined,
      },
    });
    toast(
      `${result.accepted.length} teleport${result.accepted.length === 1 ? "" : "s"} en cola`,
      "ok",
    );
    selected.clear();
    renderRoster();
  } catch (error) {
    toast(error.message, "error");
  } finally {
    el.sendBtn.disabled = selected.size === 0;
  }
});

/* --------------------------- loader modal ------------------------- */

el.linkBtn.addEventListener("click", () => el.loaderModal.showModal());
el.closeLoader.addEventListener("click", () => el.loaderModal.close());
el.copyLoader.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(el.loaderCode.textContent);
    toast("Loader copiado", "ok");
  } catch {
    toast("No se pudo copiar — selecciónalo a mano", "error");
  }
});

/* ------------------------------------------------------------------ */
/* arranque                                                            */
/* ------------------------------------------------------------------ */

setInterval(() => {
  if (snapshot?.bridge) el.metaPing.textContent = ago(snapshot.bridge.lastSeen);
}, 5000);

(async function boot() {
  try {
    const { authenticated } = await api("/api/auth/status");
    if (authenticated) return enterConsole();
  } catch {
    /* mostramos el acceso */
  }
  el.gate.hidden = false;
  el.password.focus();
})();

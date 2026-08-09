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
  places: $("places"),
  jobForm: $("jobForm"),
  jobInput: $("jobInput"),
  jobHint: $("jobHint"),
  useCurrentJob: $("useCurrentJob"),

  bridges: $("bridges"),
  bridgeTag: $("bridgeTag"),
  targetNote: $("targetNote"),
  bridgePlaces: $("bridgePlaces"),

  roster: $("roster"),
  rosterCount: $("rosterCount"),
  rosterFoot: $("rosterFoot"),
  tabPlayers: $("tabPlayers"),
  tabScan: $("tabScan"),
  scan: $("scan"),
  scanList: $("scanList"),
  scanCount: $("scanCount"),
  scanFoot: $("scanFoot"),
  scanSearch: $("scanSearch"),
  scanRefreshBtn: $("scanRefreshBtn"),
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
  controlCode: $("controlCode"),
  linkBtn: $("linkBtn"),
  copyLoader: $("copyLoader"),
  copyControl: $("copyControl"),
  closeLoader: $("closeLoader"),
  logoutBtn: $("logoutBtn"),
};

const selected = new Set();
// A qué bridge van las órdenes: "all" o el id de uno concreto.
let target = "all";
let tab = "players";
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
      el.controlCode.textContent = info.controlLoader;
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

  // bridges
  const online = state.online > 0;
  el.bridgeChip.dataset.state = online ? "on" : "off";
  el.bridgeValue.textContent = !online
    ? "ninguno"
    : state.online === 1
      ? state.bridges.find((b) => b.online)?.username || "1 en línea"
      : `${state.online} en línea`;

  renderBridges(state.bridges || []);
  renderBridgePlaces(state.bridgePlaces || []);

  // reloj del juego
  renderClock();
  renderPlaces(state.places || []);

  el.queueValue.textContent = String(state.pending ?? 0);

  // ajustes guardados
  if (!el.placeInput.dataset.dirty) el.placeInput.value = state.settings.placeId || "";
  if (!el.jobInput.dataset.dirty) el.jobInput.value = state.settings.jobId || "";

  el.placeHint.textContent = state.settings.savedPlaceIdAt
    ? `guardado ${ago(state.settings.savedPlaceIdAt)}`
    : "sin guardar todavía";
  el.placeHint.dataset.ok = state.settings.savedPlaceIdAt ? "1" : "0";

  renderRoster();
  // El contador de la pestaña se actualiza aunque no la estés mirando.
  el.scanCount.textContent = String(state.scan?.items?.length ?? 0);
  if (tab === "scan") renderScan();
  renderDestination();
}

const ACCESS_LABEL = {
  active: "corriendo",
  paused: "pausado",
  permanent: "permanente",
  locked: "sin acceso",
  blacklisted: "bloqueado",
};

/** 1234567 → "1.23M". Los números del juego crecen rápido. */
function compact(value) {
  const n = Number(value) || 0;
  if (n < 1000) return String(Math.round(n));
  const units = ["K", "M", "B", "T", "Qa", "Qi"];
  let scaled = n;
  let unit = -1;
  while (scaled >= 1000 && unit < units.length - 1) {
    scaled /= 1000;
    unit += 1;
  }
  return `${scaled >= 100 ? scaled.toFixed(0) : scaled.toFixed(2)}${units[unit]}`;
}

function mmss(seconds) {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/** Segundos que le quedan a un acceso, descontando lo que va corrido. */
function secondsLeft(access) {
  if (!access?.status) return Infinity;
  const running = access.status === "active";
  const elapsed = running ? (Date.now() - access.readAt) / 1000 : 0;
  return Math.max(0, access.remainingSeconds - elapsed);
}

/**
 * Con varios bridges el chip enseña el que antes se queda sin tiempo,
 * que es el que te va a dar problemas. Si has fijado uno como destino
 * de las órdenes, enseña el suyo.
 */
function relevantAccess() {
  const list = (snapshot?.bridges || []).filter((b) => b.online && b.access?.status);
  if (list.length === 0) return null;

  if (target !== "all") {
    return list.find((b) => b.id === target)?.access ?? null;
  }

  const timed = list.filter((b) => b.access.status === "active" || b.access.status === "paused");
  if (timed.length === 0) return list[0].access;

  return timed.reduce((worst, b) =>
    secondsLeft(b.access) < secondsLeft(worst.access) ? b : worst,
  ).access;
}

function renderClock() {
  const access = relevantAccess();

  if (!access) {
    el.clockChip.dataset.state = "unknown";
    el.clockValue.textContent = "sin datos";
    return;
  }

  el.clockChip.dataset.state =
    access.status === "paused"
      ? "paused"
      : access.status === "active" || access.status === "permanent"
        ? "running"
        : "off";

  const label = ACCESS_LABEL[access.status] ?? access.status;
  el.clockValue.textContent =
    access.status === "active" || access.status === "paused"
      ? `${label} · ${mmss(secondsLeft(access))}`
      : label;
}

/**
 * Botones para mover a los propios bridges de place. Van al destino que
 * esté elegido arriba: todos, o solo uno.
 */
function renderBridgePlaces(places) {
  const signature = places.map((p) => p.placeId).join(",");
  if (el.bridgePlaces.dataset.signature === signature) return;
  el.bridgePlaces.dataset.signature = signature;

  el.bridgePlaces.replaceChildren();

  for (const place of places) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = place.label;
    button.title = `Mover ${
      target === "all" ? "todos los bridges" : "el bridge elegido"
    } a ${place.label} — ${place.note ?? place.placeId}`;

    button.addEventListener("click", async () => {
      const who =
        target === "all"
          ? `${snapshot?.online ?? 0} bridge(s)`
          : (snapshot?.bridges ?? []).find((b) => b.id === target)?.username || "el bridge";

      try {
        await send("bridge.teleport", { placeId: place.placeId });
        toast(`Moviendo ${who} a ${place.label}`, "ok");
      } catch {
        /* el toast de error ya lo pone send() */
      }
    });

    el.bridgePlaces.append(button);
  }
}

/** Lista de bridges conectados y a cuál se le habla. */
function renderBridges(list) {
  el.bridgeTag.textContent = `${snapshot?.online ?? 0} en línea`;

  // Si el bridge elegido desaparece, las órdenes vuelven a ir a todos.
  if (target !== "all" && !list.some((b) => b.id === target && b.online)) {
    target = "all";
  }

  el.bridges.replaceChildren();

  if (list.length === 0) {
    const empty = document.createElement("div");
    empty.className = "bridges__empty";
    empty.textContent = "ningún bridge conectado todavía";
    el.bridges.append(empty);
    el.targetNote.textContent = "pega el loader en una cuenta para empezar";
    return;
  }

  const rows = [{ id: "all", username: "Todos los bridges", online: true, all: true }, ...list];

  for (const bridge of rows) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "bridge";
    row.dataset.selected = target === bridge.id ? "1" : "0";
    row.dataset.online = bridge.online ? "1" : "0";

    const led = document.createElement("i");
    led.className = "led";
    if (bridge.all) {
      led.style.background = "var(--blue)";
    } else if (bridge.online) {
      led.style.background = "var(--acid)";
    } else {
      led.style.background = "var(--red)";
    }

    const who = document.createElement("span");
    who.className = "bridge__who";
    const name = document.createElement("b");
    name.textContent = bridge.username;
    const detail = document.createElement("span");

    if (bridge.all) {
      const count = list.filter((b) => b.online).length;
      detail.textContent = `${count} conectado${count === 1 ? "" : "s"}`;
    } else if (!bridge.online) {
      detail.textContent = `caído ${ago(bridge.lastSeen)}`;
    } else {
      const job = bridge.panelJobId ? bridge.panelJobId.slice(0, 8) + "…" : "sin job";
      detail.textContent = `${bridge.playerCount} jugador${
        bridge.playerCount === 1 ? "" : "es"
      } · ${job}`;
    }
    who.append(name, detail);

    row.append(led, who);

    if (!bridge.all && bridge.access?.status) {
      const clockEl = document.createElement("span");
      clockEl.className = "bridge__clock";
      clockEl.dataset.state = bridge.access.status;
      clockEl.textContent =
        bridge.access.status === "active" || bridge.access.status === "paused"
          ? mmss(secondsLeft(bridge.access))
          : ACCESS_LABEL[bridge.access.status] ?? "";
      row.append(clockEl);
    }

    row.addEventListener("click", () => {
      target = bridge.id;
      renderBridges(snapshot?.bridges || []);
      renderRoster();
      renderScan();
      renderClock();
    });

    el.bridges.append(row);
  }

  el.targetNote.textContent =
    target === "all"
      ? "las órdenes van a todos"
      : `las órdenes van solo a ${list.find((b) => b.id === target)?.username ?? target}`;
}

function renderPlaces(places) {
  const current = el.placeInput.value.trim();
  const signature = places.map((p) => p.placeId).join(",");

  if (el.places.dataset.signature !== signature) {
    el.places.dataset.signature = signature;
    el.places.replaceChildren();

    for (const place of places) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = place.label.replace(/^SAB\s+/, "");
      button.title = `${place.label} · ${place.placeId}`;
      button.dataset.placeId = place.placeId;
      button.addEventListener("click", () => {
        el.placeInput.value = place.placeId;
        el.placeInput.dataset.dirty = "1";
        renderPlaces(snapshot?.places || []);
        renderDestination();
      });
      el.places.append(button);
    }
  }

  for (const button of el.places.children) {
    button.dataset.active = button.dataset.placeId === current ? "1" : "0";
  }
}

/**
 * Lo que los bridges han escaneado en sus plots. Solo lectura: aquí no
 * se manda nada al juego, es la foto de lo que hay.
 */
function renderScan() {
  const scan = snapshot?.scan ?? { items: [], updatedAt: 0 };
  const all = scan.items ?? [];
  const filtered = target === "all" ? all : all.filter((i) => i.bridgeId === target);

  const query = el.scanSearch.value.trim().toLowerCase();
  const visible = query
    ? filtered.filter(
        (i) =>
          i.name.toLowerCase().includes(query) ||
          i.owner.toLowerCase().includes(query) ||
          i.mutation.toLowerCase().includes(query),
      )
    : filtered;

  el.scanCount.textContent = String(all.length);
  el.scanList.replaceChildren();

  if (visible.length === 0) {
    const empty = document.createElement("div");
    empty.className = "scan__empty";
    const scanners = (snapshot?.bridges ?? []).filter((b) => b.online && b.scanner).length;
    empty.textContent = all.length
      ? "nada coincide con la búsqueda"
      : scanners > 0
        ? "escaneando…"
        : "ningún bridge está en el place del escáner";
    el.scanList.append(empty);
    el.scanFoot.textContent = scan.updatedAt
      ? `0 de ${all.length} · actualizado ${ago(scan.updatedAt)}`
      : "sin datos todavía";
    return;
  }

  // Agrupado por dueño: lo que interesa es de quién es cada cosa, no una
  // lista plana de objetos sueltos.
  const byOwner = new Map();
  for (const item of visible) {
    const key = item.owner || "Unclaimed";
    if (!byOwner.has(key)) byOwner.set(key, []);
    byOwner.get(key).push(item);
  }

  // Quien más genera, primero — y si nadie genera, quien más tiene.
  // Los plots libres, al final.
  const totalOf = (items) => items.reduce((sum, i) => sum + (Number(i.generation) || 0), 0);

  const owners = [...byOwner.entries()].sort((a, b) => {
    const aFree = a[0] === "Unclaimed";
    const bFree = b[0] === "Unclaimed";
    if (aFree !== bFree) return aFree ? 1 : -1;
    return (
      totalOf(b[1]) - totalOf(a[1]) ||
      b[1].length - a[1].length ||
      a[0].localeCompare(b[0])
    );
  });

  // Un dueño que además está en la lista de teleport se puede mandar
  // desde aquí mismo.
  const players = new Map(
    (snapshot?.players?.list ?? []).map((p) => [p.username.toLowerCase(), p]),
  );

  for (const [owner, items] of owners) {
    const player = players.get(owner.toLowerCase());

    const head = document.createElement(player ? "button" : "div");
    head.className = "scan__owner-head";
    if (player) {
      head.type = "button";
      head.dataset.linked = "1";
      head.title = `${owner} está en la lista — pulsa para seleccionarlo`;
      head.addEventListener("click", () => {
        selected.add(player.userId);
        setTab("players");
        renderRoster();
        toast(`${owner} seleccionado para teleport`, "ok");
      });
    }

    const name = document.createElement("b");
    name.textContent = owner === "Unclaimed" ? "sin dueño" : owner;
    head.append(name);

    if (player) {
      const mark = document.createElement("i");
      mark.className = "scan__linked";
      mark.textContent = "en la lista";
      head.append(mark);
    }

    const total = items.reduce((sum, i) => sum + (Number(i.generation) || 0), 0);

    const count = document.createElement("span");
    count.textContent =
      total > 0
        ? `${items.length} · ${compact(total)}/s`
        : `${items.length} objeto${items.length === 1 ? "" : "s"}`;
    count.title = `${items.length} objeto${items.length === 1 ? "" : "s"}`;
    head.append(count);

    el.scanList.append(head);

    for (const item of items.slice(0, 200)) {
      const row = document.createElement("div");
      row.className = "scan__row";

      const itemName = document.createElement("span");
      itemName.className = "scan__name";
      itemName.textContent = item.name;
      row.append(itemName);

      if (item.mutation) {
        const mutation = document.createElement("i");
        mutation.className = "scan__mut";
        mutation.textContent = item.mutation;
        row.append(mutation);
      }

      for (const trait of item.traits ?? []) {
        const tag = document.createElement("i");
        tag.className = "scan__trait";
        tag.textContent = trait;
        row.append(tag);
      }

      if (item.generation > 0) {
        const gen = document.createElement("span");
        gen.className = "scan__gen";
        gen.textContent = `${compact(item.generation)}/s`;
        row.append(gen);
      }

      const plot = document.createElement("span");
      plot.className = "scan__plot";
      plot.textContent = item.slot > 0 ? `${item.plot} · ${item.slot}` : item.plot;
      plot.title = `visto por ${item.bridgeName}`;
      row.append(plot);

      el.scanList.append(row);
    }
  }

  const grand = totalOf(visible);
  const origin = scan.source === "workspace" ? " · leído del Workspace" : "";

  el.scanFoot.textContent = scan.updatedAt
    ? `${visible.length} objeto${visible.length === 1 ? "" : "s"} · ${owners.length} dueño${
        owners.length === 1 ? "" : "s"
      }${grand > 0 ? ` · ${compact(grand)}/s en total` : ""} · ${ago(
        scan.updatedAt,
      )}${origin}`
    : "sin datos todavía";
}

function setTab(next) {
  tab = next;
  el.tabPlayers.dataset.active = next === "players" ? "1" : "0";
  el.tabScan.dataset.active = next === "scan" ? "1" : "0";

  el.roster.hidden = next !== "players";
  el.rosterFoot.hidden = next !== "players";
  document.querySelector(".roster__tools").hidden = next !== "players";
  el.scan.hidden = next !== "scan";

  if (next === "scan") renderScan();
}

function renderRoster() {
  const all = snapshot?.players?.list ?? [];
  // Con un bridge fijado, solo los que ese bridge tiene delante.
  const list = target === "all" ? all : all.filter((p) => p.bridgeId === target);
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
        : (snapshot?.online ?? 0) > 0
          ? "esperando la lista de GetTeleportCandidates…"
          : "conecta un bridge para ver jugadores";
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
  const alive = new Set(all.map((p) => p.userId));
  for (const id of [...selected]) if (!alive.has(id)) selected.delete(id);

  el.selCount.textContent = `${selected.size} seleccionado${selected.size === 1 ? "" : "s"}`;
  el.sendBtn.disabled = selected.size === 0 || (snapshot?.online ?? 0) === 0;
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

  // De qué partida viene: con varios bridges hace falta saberlo.
  if ((snapshot?.online ?? 0) > 1 && player.bridgeName) {
    const from = document.createElement("i");
    from.className = "tagline";
    from.textContent = player.bridgeName;
    name.append(from);
  }

  item.append(tick, avatar, who);
  item.addEventListener("click", () => {
    if (selected.has(player.userId)) selected.delete(player.userId);
    else selected.add(player.userId);
    renderRoster();
    renderDestination();
  });

  return item;
}

// El Job ID que cuenta es el del cuadro del panel del juego, no el que
// creemos haber mandado. Se recalcula tanto al llegar estado nuevo como
// mientras se escribe.
function renderJobHint() {
  const panelJobId = snapshot?.game?.panelJobId ?? null;
  const typed = el.jobInput.value.trim();

  if (panelJobId === null) {
    el.jobHint.textContent = snapshot?.settings?.savedJobIdAt
      ? `guardado ${ago(snapshot.settings.savedJobIdAt)}`
      : "sin guardar todavía";
    el.jobHint.dataset.ok = "0";
  } else if (panelJobId === "") {
    el.jobHint.textContent = "el panel del juego lo tiene vacío";
    el.jobHint.dataset.ok = "0";
  } else if (panelJobId === typed) {
    el.jobHint.textContent = "activo en el panel del juego";
    el.jobHint.dataset.ok = "1";
  } else {
    el.jobHint.textContent = `el panel del juego tiene ${panelJobId.slice(0, 18)}…`;
    el.jobHint.dataset.ok = "0";
  }
}

function renderDestination() {
  renderJobHint();

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
    await api("/api/command", { method: "POST", body: { type, payload, target } });
  } catch (error) {
    toast(error.message, "error");
    throw error;
  }
}

for (const button of document.querySelectorAll(".bigbtn[data-cmd]")) {
  button.addEventListener("click", () => {
    if ((snapshot?.online ?? 0) === 0) {
      toast("No hay ningún bridge conectado", "error");
      return;
    }
    send(button.dataset.cmd).catch(() => {});
  });
}

el.placeForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await send("settings.placeId", { placeId: el.placeInput.value.trim() }).catch(() => {});
  delete el.placeInput.dataset.dirty;
  renderPlaces(snapshot?.places || []);
  renderDestination();
});

el.jobForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await send("settings.jobId", { jobId: el.jobInput.value.trim() }).catch(() => {});
  delete el.jobInput.dataset.dirty;
  renderDestination();
});

// Copia el JobId del servidor donde corre el bridge: es el destino que
// se quiere el 90% de las veces y evita teclear un UUID a mano.
el.useCurrentJob.addEventListener("click", () => {
  const jobId = snapshot?.bridge?.jobId;
  if (!jobId) {
    toast("El bridge todavía no ha reportado su Job ID", "error");
    return;
  }
  el.jobInput.value = jobId;
  el.jobInput.dataset.dirty = "1";
  renderDestination();
  toast("Job ID del servidor actual — pulsa guardar", "info");
});

for (const input of [el.placeInput, el.jobInput]) {
  input.addEventListener("input", () => {
    input.dataset.dirty = "1";
    renderPlaces(snapshot?.places || []);
    renderDestination();
  });
}

el.search.addEventListener("input", renderRoster);
el.scanSearch.addEventListener("input", renderScan);
el.tabPlayers.addEventListener("click", () => setTab("players"));
el.tabScan.addEventListener("click", () => setTab("scan"));

el.scanRefreshBtn.addEventListener("click", () => {
  send("scan.refresh").catch(() => {});
});

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
    .map((p) => ({ userId: p.userId, username: p.username, bridgeId: p.bridgeId }));

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

async function copy(text, what) {
  try {
    await navigator.clipboard.writeText(text);
    toast(`${what} copiado`, "ok");
  } catch {
    toast("No se pudo copiar — selecciónalo a mano", "error");
  }
}

el.copyLoader.addEventListener("click", () => copy(el.loaderCode.textContent, "Loader del bridge"));
el.copyControl.addEventListener("click", () => copy(el.controlCode.textContent, "Loader del mando"));

/* ------------------------------------------------------------------ */
/* arranque                                                            */
/* ------------------------------------------------------------------ */

// Las cuentas atrás corren en el navegador; los bridges solo releen el
// estado del juego cada veinte segundos.
setInterval(() => {
  if (!snapshot?.bridges?.length) return;
  renderClock();
  for (const row of el.bridges.children) {
    const clockEl = row.querySelector?.(".bridge__clock");
    if (!clockEl) continue;
    const bridge = snapshot.bridges.find((b) => b.username === row.querySelector("b").textContent);
    if (bridge?.access?.status === "active") clockEl.textContent = mmss(secondsLeft(bridge.access));
  }
}, 1000);

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

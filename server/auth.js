import { randomBytes, timingSafeEqual } from "node:crypto";

const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12 h
const COOKIE = "ms_session";

/** @type {Map<string, number>} token -> expiración */
const sessions = new Map();

function randomSecret(bytes = 18) {
  return randomBytes(bytes).toString("base64url");
}

/**
 * Password del panel y clave del bridge. Si no vienen por entorno se generan
 * al arrancar y se imprimen una vez en los logs de Railway.
 */
export const PANEL_PASSWORD = process.env.PANEL_PASSWORD || randomSecret(9);
export const BRIDGE_KEY = process.env.BRIDGE_KEY || randomSecret(16);

export const generatedPassword = !process.env.PANEL_PASSWORD;
export const generatedBridgeKey = !process.env.BRIDGE_KEY;

function safeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

export function checkPassword(candidate) {
  return safeEqual(candidate ?? "", PANEL_PASSWORD);
}

export function checkBridgeKey(candidate) {
  return safeEqual(candidate ?? "", BRIDGE_KEY);
}

export function createSession() {
  const token = randomSecret(24);
  sessions.set(token, Date.now() + SESSION_TTL_MS);
  return token;
}

export function destroySession(token) {
  if (token) sessions.delete(token);
}

export function isValidSession(token) {
  if (!token) return false;
  const expiresAt = sessions.get(token);
  if (!expiresAt) return false;
  if (expiresAt < Date.now()) {
    sessions.delete(token);
    return false;
  }
  return true;
}

export function parseCookies(header = "") {
  const out = {};
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    out[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return out;
}

export function sessionFromRequest(req) {
  const cookies = parseCookies(req.headers.cookie || "");
  return cookies[COOKIE] || null;
}

export function setSessionCookie(res, token) {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  res.setHeader(
    "Set-Cookie",
    `${COOKIE}=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${
      SESSION_TTL_MS / 1000
    }${secure}`,
  );
}

export function clearSessionCookie(res) {
  res.setHeader("Set-Cookie", `${COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0`);
}

/** Middleware express para las rutas del panel. */
export function requirePanelAuth(req, res, next) {
  if (isValidSession(sessionFromRequest(req))) return next();
  res.status(401).json({ error: "no autenticado" });
}

/** Middleware express para las rutas del bridge (script de Roblox). */
export function requireBridgeAuth(req, res, next) {
  const key = req.headers["x-bridge-key"] || req.query.key;
  if (checkBridgeKey(key)) return next();
  res.status(401).json({ error: "bridge key inválida" });
}

/**
 * Ejecuta tests/remotes.test.lua en una VM de Lua con Roblox mockeado.
 *
 * No hace falta Studio ni un executor: se comprueba que cada función de
 * roblox/remotes.lua llama al remote correcto con los argumentos y los
 * tipos exactos que espera el juego.
 *
 *   npm test
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const here = path.dirname(fileURLToPath(import.meta.url));

const remotesSource = readFileSync(path.join(here, "..", "roblox", "remotes.lua"), "utf8");
const testSource = readFileSync(path.join(here, "remotes.test.lua"), "utf8");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

// El test carga el módulo desde esta global en vez de tocar el disco.
lua.lua_pushstring(L, to_luastring(remotesSource));
lua.lua_setglobal(L, to_luastring("REMOTES_SRC"));

if (lauxlib.luaL_dostring(L, to_luastring(testSource)) !== lua.LUA_OK) {
  console.error("\n" + lua.lua_tojsstring(L, -1));
  process.exit(1);
}

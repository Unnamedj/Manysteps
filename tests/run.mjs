/**
 * Ejecuta las pruebas de los scripts de Roblox en una VM de Lua.
 *
 * No hace falta Studio ni un executor:
 *   - remotes.test.lua  comprueba que cada función llama al remote
 *                       correcto con los argumentos y tipos exactos.
 *   - control.test.lua  carga el mando entero sobre un Roblox mockeado y
 *                       dispara los clics para ver qué manda al panel.
 *
 *   npm test
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const here = path.dirname(fileURLToPath(import.meta.url));

const read = (...parts) => readFileSync(path.join(here, ...parts), "utf8");

const suites = [
  {
    name: "remotes.lua",
    test: "remotes.test.lua",
    globals: { REMOTES_SRC: read("..", "roblox", "remotes.lua") },
  },
  {
    name: "control.lua",
    test: "control.test.lua",
    globals: {
      CONTROL_SRC: read("..", "roblox", "control.lua"),
      MOCK_SRC: read("roblox_mock.lua"),
    },
  },
];

let failed = false;

for (const suite of suites) {
  console.log(`\n=== ${suite.name} ===`);

  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  for (const [name, source] of Object.entries(suite.globals)) {
    lua.lua_pushstring(L, to_luastring(source));
    lua.lua_setglobal(L, to_luastring(name));
  }

  if (lauxlib.luaL_dostring(L, to_luastring(read(suite.test))) !== lua.LUA_OK) {
    console.error("\n" + lua.lua_tojsstring(L, -1));
    failed = true;
  }
}

if (failed) process.exit(1);

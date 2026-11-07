/* Garry's Mod binary module: gmcl_omniplay_win32.dll / gmcl_omniplay_win64.dll in garrysmod/lua/bin/.
 * OmniPlay installs it for the user (Games tab). Loaded by the omniplay_bridge addon with
 * require("omniplay"); gamemodes use the addon's OmniPlay.* API, not this table directly.
 *
 * Plain C against the Lua API that GMod's lua_shared.dll exports, so it builds with MinGW and
 * doesn't depend on the C++ ILuaBase vtable layout.
 *
 *   omniplay_native.Version             -> 1
 *   omniplay_native.Running()           -> bool
 *   omniplay_native.State()             -> json string, seq   (nil when OmniPlay isn't running)
 *   omniplay_native.Values()            -> speed_kmh, cadence, power, hr, grade, moving, gait (0-3)
 *   omniplay_native.SetGame(name)  SetGrade(pct|nil)  SetBeltSpeed(kmh|nil)  TakeInput(bool)
 *   omniplay_native.SetInfo(text)  Release()
 *
 * License: OmniPlay SDK License (sdk/LICENSE). */
#include "../omniplay.h"
#include <math.h>
#include <stddef.h>

#ifdef _WIN32
#  include <windows.h>
#  define EXPORT __declspec(dllexport)
static void *lua_fn(const char *name) {
    HMODULE m = GetModuleHandleA("lua_shared.dll");
    return m ? (void *)GetProcAddress(m, name) : NULL;
}
#else
#  include <dlfcn.h>
#  define EXPORT __attribute__((visibility("default")))
static void *lua_fn(const char *name) { return dlsym(RTLD_DEFAULT, name); } /* tests: the host's LuaJIT */
#endif

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *);
#define LUA_GLOBALSINDEX (-10002)
#define LUA_TNIL 0

static void (*p_createtable)(lua_State *, int, int);
static void (*p_pushcclosure)(lua_State *, lua_CFunction, int);
static void (*p_setfield)(lua_State *, int, const char *);
static void (*p_pushboolean)(lua_State *, int);
static void (*p_pushlstring)(lua_State *, const char *, size_t);
static void (*p_pushnumber)(lua_State *, double);
static void (*p_pushnil)(lua_State *);
static const char *(*p_tolstring)(lua_State *, int, size_t *);
static double (*p_tonumber)(lua_State *, int);
static int (*p_toboolean)(lua_State *, int);
static int (*p_type)(lua_State *, int);

static int f_running(lua_State *L) { p_pushboolean(L, omniplay_running()); return 1; }

static char json[8192];
static int f_state(lua_State *L) {
    unsigned seq = 0;
    int n = omniplay_state_json(json, sizeof json, &seq);
    if (n <= 0) { p_pushnil(L); return 1; }
    p_pushlstring(L, json, (size_t)n);
    p_pushnumber(L, seq);
    return 2;
}

static void pushf(lua_State *L, float v) { if (v != v) p_pushnil(L); else p_pushnumber(L, v); }
static int f_values(lua_State *L) {
    OmniPlayValues v;
    if (!omniplay_values(&v)) { p_pushnil(L); return 1; }
    pushf(L, v.speed_kmh); pushf(L, v.cadence); pushf(L, v.power); pushf(L, v.hr); pushf(L, v.grade);
    p_pushboolean(L, v.moving); p_pushnumber(L, v.gait);
    return 7;
}

static const char *arg_str(lua_State *L) { const char *s = p_tolstring(L, 1, NULL); return s ? s : ""; }
static float arg_num(lua_State *L) { return p_type(L, 1) == LUA_TNIL || p_type(L, 1) < 0 ? NAN : (float)p_tonumber(L, 1); }
static int f_setgame(lua_State *L) { omniplay_set_game(arg_str(L)); return 0; }
static int f_setgrade(lua_State *L) { omniplay_set_grade(arg_num(L)); return 0; }
static int f_setbelt(lua_State *L) { omniplay_set_belt_speed(arg_num(L)); return 0; }
static int f_takeinput(lua_State *L) { omniplay_take_input(p_toboolean(L, 1)); return 0; }
static int f_setinfo(lua_State *L) { omniplay_set_info(arg_str(L)); return 0; }
static int f_release(lua_State *L) { (void)L; omniplay_release(); return 0; }

static void reg(lua_State *L, const char *name, lua_CFunction f) { p_pushcclosure(L, f, 0); p_setfield(L, -2, name); }

EXPORT int gmod13_open(lua_State *L) {
#define GET(v, n) if (!(*(void **)&v = lua_fn(n))) return 0
    GET(p_createtable, "lua_createtable"); GET(p_pushcclosure, "lua_pushcclosure"); GET(p_setfield, "lua_setfield");
    GET(p_pushboolean, "lua_pushboolean"); GET(p_pushlstring, "lua_pushlstring"); GET(p_pushnumber, "lua_pushnumber");
    GET(p_pushnil, "lua_pushnil"); GET(p_tolstring, "lua_tolstring"); GET(p_tonumber, "lua_tonumber");
    GET(p_toboolean, "lua_toboolean"); GET(p_type, "lua_type");
    p_createtable(L, 0, 12);
    p_pushnumber(L, OMNIPLAY_VERSION); p_setfield(L, -2, "Version");
    reg(L, "Running", f_running);
    reg(L, "State", f_state);
    reg(L, "Values", f_values);
    reg(L, "SetGame", f_setgame);
    reg(L, "SetGrade", f_setgrade);
    reg(L, "SetBeltSpeed", f_setbelt);
    reg(L, "TakeInput", f_takeinput);
    reg(L, "SetInfo", f_setinfo);
    reg(L, "Release", f_release);
    p_setfield(L, LUA_GLOBALSINDEX, "omniplay_native");
    return 0;
}

EXPORT int gmod13_close(lua_State *L) { (void)L; omniplay_release(); return 0; }

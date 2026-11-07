/* OmniPlay SDK — read the player's bike / walking pad / footpod and send hills back.
 *
 * OmniPlay (the desktop app) publishes everything in a small block of shared memory on the
 * same PC. This header plus omniplay.c (or omniplay_client.dll) reads it. No network, no
 * files, about 1 microsecond per read, works from any language that can call a C function.
 *
 * Typical game loop:
 *     omniplay_set_game("My Game");            // once
 *     OmniPlayValues v;
 *     if (omniplay_values(&v)) {               // every frame: 1 while OmniPlay is running
 *         player_speed = v.speed_kmh;
 *     }
 *     omniplay_set_grade(hill_under_player);   // whenever it changes (NAN = flat)
 *
 * Your game counts as connected while it keeps calling omniplay_values() or
 * omniplay_state_json(); 3 seconds after it stops, OmniPlay flattens the hill and gives
 * input back to the keys.
 *
 * License: OmniPlay SDK License (MIT + one condition: don't sell OmniPlay support as a
 * separate purchase, add-on or DLC). See sdk/LICENSE.
 */
#ifndef OMNIPLAY_H
#define OMNIPLAY_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(OMNIPLAY_BUILD_DLL)
#  define OMNIPLAY_API __declspec(dllexport)
#elif defined(_WIN32) && defined(OMNIPLAY_USE_DLL)
#  define OMNIPLAY_API __declspec(dllimport)
#else
#  define OMNIPLAY_API
#endif

#define OMNIPLAY_VERSION 1

/* gait */
#define OMNIPLAY_STOPPED 0
#define OMNIPLAY_WALK    1
#define OMNIPLAY_RUN     2
#define OMNIPLAY_SPRINT  3
/* kind of machine */
#define OMNIPLAY_NONE      0
#define OMNIPLAY_BIKE      1
#define OMNIPLAY_TREADMILL 2   /* walking pads too */
#define OMNIPLAY_FOOTPOD   3

/* Numbers that aren't reported by the user's devices are NAN (check with x != x). */
typedef struct OmniPlayValues {
    float speed_kmh;   /* 0 when stopped */
    float cadence;     /* rpm on a bike, steps per minute walking/running */
    float power;       /* watts, NAN if unknown */
    float hr;          /* heart rate bpm, NAN if no strap */
    float grade;       /* hill in % currently applied to the machine */
    float distance_m;  /* this workout */
    float elapsed_s;   /* this workout */
    float steps;       /* step counter, NAN if unknown */
    int   moving;      /* 1 while pedalling / walking */
    int   gait;        /* OMNIPLAY_STOPPED .. OMNIPLAY_SPRINT, from the user's game profile */
    int   kind;        /* OMNIPLAY_NONE .. OMNIPLAY_FOOTPOD */
    int   connected;   /* 1 when a device is connected in OmniPlay */
} OmniPlayValues;

/* Is OmniPlay running right now? (cheap; safe to call every frame) */
OMNIPLAY_API int  omniplay_running(void);

/* Fill *out with the latest numbers. Returns 1 if OmniPlay is running, 0 otherwise
 * (then *out is zeroed). Also tells OmniPlay your game is still there. */
OMNIPLAY_API int  omniplay_values(OmniPlayValues *out);

/* The full state as JSON (same fields as docs/API.md: device name, camera, recording...).
 * Copies up to size-1 bytes plus a 0. Returns the length, or 0 if OmniPlay isn't running.
 * *seq (optional) gets a number that changes with every new state. */
OMNIPLAY_API int  omniplay_state_json(char *buf, int size, unsigned *seq);

/* Requests. They are state, not events: OmniPlay keeps the last values. */
OMNIPLAY_API void omniplay_set_game(const char *name);   /* shown in OmniPlay, saved with the workout */
OMNIPLAY_API void omniplay_set_grade(float pct);         /* -10..20 %, NAN = flat */
OMNIPLAY_API void omniplay_set_belt_speed(float kmh);    /* treadmill speed, NAN = leave it */
OMNIPLAY_API void omniplay_take_input(int on);           /* 1 = OmniPlay stops pressing keys */
OMNIPLAY_API void omniplay_set_info(const char *text);   /* a line in OmniPlay's log, for debugging */

/* Let go: flat hill, keys back on. Call when your game quits (optional; it also
 * happens 3 s after you stop calling omniplay_values). */
OMNIPLAY_API void omniplay_release(void);

/* ---------- shared memory layout (for languages that map it themselves) ----------
 * Windows: CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, OMNIPLAY_SHM_SIZE,
 *          "Local\\OmniPlay_v1"); Linux/macOS: shm_open("/OmniPlay_v1").
 * Little-endian. Times are seconds of the system's monotonic clock (Windows: GetTickCount64()/1000).
 *
 *   0    char[8]  "OMNIPLAY"          written by the app
 *   8    u32      version (1)
 *   12   u32      app process id, 0 after the app closed
 *   16   u32      state seq           odd while the app writes; read again if it changed
 *   20   u32      state JSON length
 *   24   f64      app beat            the app's clock at the last write (every 50 ms)
 *   32   OmniPlayValues (48 bytes)
 *   96   char[8096] state JSON
 *   8192 u32      request seq         odd while the game writes
 *   8196 u32      request JSON length
 *   8200 u32      game process id
 *   8208 f64      game beat           the game's clock; refresh it at least every 1 s
 *   8216 char[4096] request JSON      e.g. {"game":"My Game","grade":4.5,"take_input":true}
 */
#define OMNIPLAY_SHM_NAME_WIN "Local\\OmniPlay_v1"
#define OMNIPLAY_SHM_NAME_POSIX "/OmniPlay_v1"
#define OMNIPLAY_SHM_SIZE 16384

#ifdef __cplusplus
}
#endif
#endif

/* OmniPlay SDK client — see omniplay.h. Build into your game, or as omniplay_client.dll:
 *   x86_64-w64-mingw32-gcc -shared -O2 -DOMNIPLAY_BUILD_DLL -o omniplay_client.dll omniplay.c
 * License: OmniPlay SDK License (sdk/LICENSE). */
#include "omniplay.h"
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <stdint.h>

#ifdef _WIN32
#  include <windows.h>
static double now_s(void) { return (double)GetTickCount64() / 1000.0; }
static unsigned my_pid(void) { return (unsigned)GetCurrentProcessId(); }
#  define BARRIER() MemoryBarrier()
#else
#  include <sys/mman.h>
#  include <sys/stat.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <time.h>
static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static unsigned my_pid(void) { return (unsigned)getpid(); }
#  define BARRIER() __sync_synchronize()
#endif

#define OFF_STATE_SEQ 16
#define OFF_STATE_LEN 20
#define OFF_APP_BEAT  24
#define OFF_VALUES    32
#define OFF_STATE     96
#define STATE_MAX     (8192 - 96)
#define OFF_REQ_SEQ   8192
#define OFF_REQ_LEN   8196
#define OFF_GAME_PID  8200
#define OFF_GAME_BEAT 8208
#define OFF_REQ       8216
#define REQ_MAX       4096

static unsigned char *mem = NULL;
static double last_try = -10;

static unsigned char *shm(void) {
    if (mem) return mem;
    double t = now_s();
    if (t - last_try < 1.0) return NULL; /* don't hammer the OS when OmniPlay isn't there */
    last_try = t;
#ifdef _WIN32
    /* create-or-open: works whichever side starts first */
    HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, OMNIPLAY_SHM_SIZE, OMNIPLAY_SHM_NAME_WIN);
    if (!h) return NULL;
    mem = (unsigned char *)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, OMNIPLAY_SHM_SIZE);
    if (!mem) CloseHandle(h);
#else
    int fd = shm_open(OMNIPLAY_SHM_NAME_POSIX, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return NULL;
    if (ftruncate(fd, OMNIPLAY_SHM_SIZE) != 0) { close(fd); return NULL; }
    void *p = mmap(NULL, OMNIPLAY_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    mem = p == MAP_FAILED ? NULL : (unsigned char *)p;
#endif
    return mem;
}

#define U32(o) (*(volatile uint32_t *)(mem + (o)))
#define F64(o) (*(volatile double *)(mem + (o)))

static int app_alive(void) {
    if (!shm()) return 0;
    if (memcmp(mem, "OMNIPLAY", 8) != 0 || U32(8) != OMNIPLAY_VERSION || U32(12) == 0) return 0;
    double age = now_s() - F64(OFF_APP_BEAT);
    return age < 2.0 && age > -2.0;
}

/* ---------- requests: we keep the whole request and rewrite it on every change ---------- */
static char r_game[128] = "", r_info[320] = "";
static float r_grade = NAN, r_belt = NAN;
static int r_take = -1, r_used = 0, r_release = 0;

static void json_str(char *dst, size_t n, const char *s) {
    size_t j = 0;
    for (; *s && j + 7 < n; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { dst[j++] = '\\'; dst[j++] = c; }
        else if (c < 0x20) j += snprintf(dst + j, n - j, "\\u%04x", c);
        else dst[j++] = c;
    }
    dst[j] = 0;
}

static void beat(void) {
    if (!mem) return;
    U32(OFF_GAME_PID) = my_pid();
    F64(OFF_GAME_BEAT) = now_s();
}

static void send_request(void) {
    if (!shm()) return;
    char game[300], info[700], buf[REQ_MAX];
    json_str(game, sizeof game, r_game[0] ? r_game : "Game");
    json_str(info, sizeof info, r_info);
    int n = snprintf(buf, sizeof buf, "{\"game\":\"%s\"", game);
    if (r_grade == r_grade) n += snprintf(buf + n, sizeof buf - n, ",\"grade\":%.2f", r_grade);
    else n += snprintf(buf + n, sizeof buf - n, ",\"grade\":false");
    if (r_belt == r_belt) n += snprintf(buf + n, sizeof buf - n, ",\"belt_speed\":%.2f", r_belt);
    if (r_take >= 0) n += snprintf(buf + n, sizeof buf - n, ",\"take_input\":%s", r_take ? "true" : "false");
    if (info[0]) n += snprintf(buf + n, sizeof buf - n, ",\"info\":\"%s\"", info);
    if (r_release) n += snprintf(buf + n, sizeof buf - n, ",\"release\":true");
    n += snprintf(buf + n, sizeof buf - n, "}");
    uint32_t s = U32(OFF_REQ_SEQ);
    if (s & 1) s++;
    U32(OFF_REQ_SEQ) = s + 1; BARRIER();          /* odd: writing */
    memcpy(mem + OFF_REQ, buf, (size_t)n + 1);
    U32(OFF_REQ_LEN) = (uint32_t)n;
    beat();
    BARRIER(); U32(OFF_REQ_SEQ) = s + 2;          /* even: done */
}

OMNIPLAY_API int omniplay_running(void) { return app_alive(); }

OMNIPLAY_API int omniplay_values(OmniPlayValues *out) {
    if (out) memset(out, 0, sizeof *out);
    if (!app_alive()) return 0;
    if (r_used) beat();
    if (!out) return 1;
    for (int tries = 0; tries < 50; tries++) {
        uint32_t a = U32(OFF_STATE_SEQ);
        if (a & 1) continue;
        BARRIER();
        memcpy(out, (const void *)(mem + OFF_VALUES), sizeof *out);
        BARRIER();
        if (U32(OFF_STATE_SEQ) == a) return 1;
    }
    return 1;
}

OMNIPLAY_API int omniplay_state_json(char *buf, int size, unsigned *seq) {
    if (!buf || size <= 0) return 0;
    buf[0] = 0;
    if (!app_alive()) return 0;
    if (r_used) beat();
    for (int tries = 0; tries < 50; tries++) {
        uint32_t a = U32(OFF_STATE_SEQ);
        if (a & 1) continue;
        BARRIER();
        uint32_t len = U32(OFF_STATE_LEN);
        if (len > STATE_MAX - 1) len = STATE_MAX - 1;
        if ((int)len > size - 1) len = (uint32_t)(size - 1);
        memcpy(buf, (const void *)(mem + OFF_STATE), len);
        buf[len] = 0;
        BARRIER();
        if (U32(OFF_STATE_SEQ) == a) { if (seq) *seq = a; return (int)len; }
    }
    buf[0] = 0;
    return 0;
}

#define CHANGED() do { r_used = 1; r_release = 0; send_request(); } while (0)
OMNIPLAY_API void omniplay_set_game(const char *name) {
    snprintf(r_game, sizeof r_game, "%s", name ? name : ""); CHANGED();
}
OMNIPLAY_API void omniplay_set_grade(float pct) {
    if (pct == pct) pct = pct < -10 ? -10 : pct > 20 ? 20 : pct;
    if ((pct != pct && r_grade != r_grade) || pct == r_grade) { r_used = 1; beat(); return; }
    r_grade = pct; CHANGED();
}
OMNIPLAY_API void omniplay_set_belt_speed(float kmh) { r_belt = kmh; CHANGED(); }
OMNIPLAY_API void omniplay_take_input(int on) { r_take = on ? 1 : 0; CHANGED(); }
OMNIPLAY_API void omniplay_set_info(const char *text) {
    snprintf(r_info, sizeof r_info, "%s", text ? text : ""); CHANGED();
}
OMNIPLAY_API void omniplay_release(void) {
    r_grade = NAN; r_belt = NAN; r_take = 0; r_release = 1;
    send_request();
    r_used = 0;
}

/* Checks the Windows helper's write queue without Bluetooth: the real omniplay_ble.c with each
 * write replaced by a fake that takes 150 ms (a slow bike). sb_write_h must return at once, the
 * writes must go out in order, a full queue must say so, and closing must stop the writer.
 * Build: x86_64-w64-mingw32-gcc -O2 -o test_writes.exe tests/native/test_writes.c -lruntimeobject -lole32 -lws2_32
 * Run on Windows (or Wine). */
#define OMNIPLAY_FAKE_WRITE fake_write
#include "../../native/omniplay_ble.c"

static unsigned char got[64]; static volatile LONG ngot;
static int fake_write(Conn *c, const unsigned char *data, int len)
{
    (void)c; (void)len;
    Sleep(150);
    got[InterlockedIncrement(&ngot) - 1] = data[0];
    return 0;
}

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

int main(void)
{
    init();
    Conn *c = &g_conns[0];
    memset(c, 0, sizeof *c);
    c->used = 1; c->write = (void *)1; c->state = 2;
    c->wevent = CreateEventW(NULL, FALSE, FALSE, NULL);
    c->wthread = CreateThread(NULL, 0, writer_thread, c, 0, NULL);

    LARGE_INTEGER f, t0, t1; QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < 5; i++) { unsigned char b[3] = { (unsigned char)(0x10 + i), 0, 0 }; CHECK(sb_write_h(0, b, 3) == 0, "write %d not queued", i); }
    QueryPerformanceCounter(&t1);
    double ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
    CHECK(ms < 20, "5 writes took %.1f ms on the calling thread (should be instant)", ms);
    printf("5 writes queued in %.2f ms\n", ms);

    Sleep(1100);  /* 5 x 150 ms */
    CHECK(ngot == 5, "%ld of 5 writes done", (long)ngot);
    for (int i = 0; i < ngot; i++) CHECK(got[i] == 0x10 + i, "write %d out of order: %02X", i, got[i]);

    /* a full queue says so instead of blocking */
    int full = 0;
    for (int i = 0; i < WQCAP + 4; i++) { unsigned char b[1] = { 0x40 }; if (sb_write_h(0, b, 1) == -5) full = 1; }
    CHECK(full, "a full queue should return -5");
    unsigned char big[WMAX + 1] = { 0 };
    CHECK(sb_write_h(0, big, WMAX + 1) == -2, "too long a write should return -2");
    CHECK(sb_write_h(5, big, 1) == -1, "unknown connection should return -1");

    /* closing stops the writer quickly even with writes waiting */
    QueryPerformanceCounter(&t0);
    InterlockedExchange(&c->wstop, 1); SetEvent(c->wevent);
    DWORD w = WaitForSingleObject(c->wthread, 2000);
    QueryPerformanceCounter(&t1);
    CHECK(w == WAIT_OBJECT_0, "writer thread didn't stop");
    printf("writer stopped in %.0f ms\n", (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart);

    printf(fails ? "native write tests FAILED\n" : "native write tests passed\n");
    return fails ? 1 : 0;
}

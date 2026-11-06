/*
 * omniplay_ble.dll - small Windows BLE helper for OmniPlay (used from LuaJIT FFI).
 *
 * Uses the WinRT Bluetooth API (Windows 10/11), the same one apps like Zwift use,
 * so the device does NOT need to be paired in Windows settings. It scans for
 * advertisements, connects by Bluetooth address, subscribes to one notify
 * characteristic and writes to one write characteristic.
 *
 * WinRT is called through raw vtable slots (no C++/WinRT needed). Slot numbers
 * and interface IDs come from the Windows metadata (cross-checked against the
 * Wine IDL files and the windows-rs bindings). Delegate IIDs are the standard
 * WinRT parameterized-interface GUIDs for the two event handler types used.
 *
 * Notifications and scan results arrive on Windows thread-pool threads, so they
 * are queued here behind a lock and Lua pulls them with sb_read()/sb_scan_list().
 * Lua is never called back, which is what keeps this safe for LuaJIT.
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#define API __declspec(dllexport)

typedef struct { INT64 value; } EvToken;  /* EventRegistrationToken */
#define EventRegistrationToken EvToken

/* ---------- raw vtable helpers ---------- */
#define VT(o) (*(void ***)(o))
#define FN(o, slot, T) ((T)VT(o)[slot])
typedef HRESULT (WINAPI *QI_T)(void *, REFIID, void **);
typedef ULONG (WINAPI *REL_T)(void *);
typedef HRESULT (WINAPI *GETPTR_T)(void *, void **);
typedef HRESULT (WINAPI *GETU32_T)(void *, UINT32 *);
typedef HRESULT (WINAPI *GETI32_T)(void *, INT32 *);

static void rel(void *o) { if (o) FN(o, 2, REL_T)(o); }
static HRESULT qi(void *o, const GUID *iid, void **out) { *out = NULL; return FN(o, 0, QI_T)(o, iid, out); }

/* ---------- interface IDs ---------- */
#define G(n, a, b, c, d0, d1, d2, d3, d4, d5, d6, d7) static const GUID n = { a, b, c, { d0, d1, d2, d3, d4, d5, d6, d7 } }
G(IID_IUnknown_, 0x00000000, 0x0000, 0x0000, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
G(IID_IAgileObject_, 0x94ea2b94, 0xe9cc, 0x49e0, 0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90);
G(IID_IAsyncInfo_, 0x00000036, 0x0000, 0x0000, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
G(IID_IClosable_, 0x30d5a829, 0x7fa4, 0x4026, 0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e);
G(IID_IBufferFactory_, 0x71af914d, 0xc10f, 0x484b, 0xbc, 0x50, 0x14, 0xbc, 0x62, 0x3b, 0x3a, 0x27);
G(IID_IBufferByteAccess_, 0x905a0fef, 0xbc53, 0x11df, 0x8c, 0x49, 0x00, 0x1e, 0x4f, 0xc6, 0x86, 0xda);
G(IID_IBLEAdvWatcher, 0xa6ac336f, 0xf3d3, 0x4297, 0x8d, 0x6c, 0xc8, 0x1e, 0xa6, 0x62, 0x3f, 0x40);
G(IID_IBLEDeviceStatics, 0xc8cf1a19, 0xf0b6, 0x4bf0, 0x86, 0x89, 0x41, 0x30, 0x3d, 0xe2, 0xd9, 0xf4);
G(IID_IBLEDevice3, 0xaee9e493, 0x44ac, 0x40dc, 0xaf, 0x33, 0xb2, 0xc1, 0x3c, 0x01, 0xca, 0x46);
G(IID_IGattDeviceService3, 0xb293a950, 0x0c53, 0x437c, 0xa9, 0xb3, 0x5c, 0x32, 0x10, 0xc6, 0xe5, 0x69);
/* TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs> */
G(IID_ReceivedHandler, 0x90eb4eca, 0xd465, 0x5ea0, 0xa6, 0x1c, 0x03, 0x3c, 0x8c, 0x5e, 0xce, 0xf2);
/* TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> */
G(IID_ValueChangedHandler, 0xc1f420f6, 0x6292, 0x5760, 0xa2, 0xc9, 0x9d, 0xdf, 0x98, 0x68, 0x3c, 0xfc);

/* vtable slots (0-2 IUnknown, 3-5 IInspectable) */
enum {
    AI_STATUS = 7, AI_ERRORCODE = 8, AI_CANCEL = 9,     /* IAsyncInfo */
    OP_GETRESULTS = 8,                                  /* IAsyncOperation<T> */
    VV_GETAT = 6, VV_SIZE = 7,                          /* IVectorView<T> */
    W_PUT_SCANMODE = 12, W_START = 17, W_STOP = 18, W_ADD_RECEIVED = 19, W_REMOVE_RECEIVED = 20,
    RA_RSSI = 6, RA_ADDRESS = 7, RA_ADVERTISEMENT = 10, AD_LOCALNAME = 8, AD_SERVICEUUIDS = 10,
    VEC_GETAT = 6, VEC_SIZE = 7,                        /* IVector<T> */
    DS_FROMADDRESS = 7,                                 /* IBluetoothLEDeviceStatics */
    D3_SERVICES_FOR_UUID_MODE = 11,                     /* IBluetoothLEDevice3 */
    SR_STATUS = 6, SR_SERVICES = 8,                     /* IGattDeviceServicesResult */
    S3_CHARS_FOR_UUID_MODE = 14,                        /* IGattDeviceService3 */
    CR_STATUS = 6, CR_CHARS = 8,                        /* IGattCharacteristicsResult */
    C_PROPS = 7, C_UUID = 11, C_WRITE_OPT = 17, C_WRITE_CCCD = 19, C_ADD_CHANGED = 20, C_REMOVE_CHANGED = 21,
    VC_VALUE = 6,                                       /* IGattValueChangedEventArgs */
    BF_CREATE = 6, B_LENGTH = 7, B_PUT_LENGTH = 8, BBA_BUFFER = 3,
    CL_CLOSE = 6,
};

/* ---------- shared state ---------- */
#define QCAP 256
#define PKTMAX 512
#define MAXDEV 48

typedef struct { UINT64 addr; INT16 rssi; char name[64]; DWORD seen; unsigned svc; } Dev;

/* Advertised service flags reported by sb_scan_list */
enum { SV_FTMS = 1, SV_RSC = 2, SV_CSC = 4, SV_POWER = 8, SV_HR = 16, SV_FFF0 = 32 };

static CRITICAL_SECTION g_lock;
static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;
static char g_err[512], g_status[256];
static volatile LONG g_state;            /* 0 idle, 1 connecting, 2 connected, -1 failed */
static unsigned char g_q[QCAP][PKTMAX];
static int g_qlen[QCAP], g_qwhich[QCAP], g_qhead, g_qtail, g_dropped;
static Dev g_devs[MAXDEV];
static int g_ndev;

static void *g_watcher;
static EventRegistrationToken g_recv_tok;
#define MAXNOTIFY 4
static void *g_device, *g_service, *g_notify[MAXNOTIFY], *g_write, *g_buffactory;
static EventRegistrationToken g_change_tok[MAXNOTIFY];
static int g_write_noresp;
static HANDLE g_thread;
static GUID g_svc, g_nchar[MAXNOTIFY], g_wchar;
static int g_nnotify, g_has_w;
static UINT64 g_addr;
static INT32 g_cache_mode = 1; /* 1 = Uncached (first connect), 0 = Cached (fast reconnect) */

static BOOL CALLBACK init_once(PINIT_ONCE o, PVOID p, PVOID *c) { (void)o; (void)p; (void)c; InitializeCriticalSection(&g_lock); return TRUE; }
static void init(void) { InitOnceExecuteOnce(&g_once, init_once, NULL, NULL); }
static __thread int t_ro;
static void ensure_ro(void) { if (!t_ro) { RoInitialize(RO_INIT_MULTITHREADED); t_ro = 1; } }

static void set_status(const char *s) { EnterCriticalSection(&g_lock); snprintf(g_status, sizeof g_status, "%s", s); LeaveCriticalSection(&g_lock); }
static void set_err(const char *what, HRESULT hr)
{
    EnterCriticalSection(&g_lock);
    snprintf(g_err, sizeof g_err, "%s (0x%08lX)", what, (unsigned long)hr);
    LeaveCriticalSection(&g_lock);
}

static const GUID BASE_GUID = { 0, 0, 0x1000, { 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb } };
static int parse_uuid(const char *s, GUID *out)
{
    unsigned int a, b, c, d[8];
    if (strlen(s) <= 8) { *out = BASE_GUID; out->Data1 = (unsigned long)strtoul(s, NULL, 16); return 1; }
    if (sscanf(s, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &a, &b, &c,
               &d[0], &d[1], &d[2], &d[3], &d[4], &d[5], &d[6], &d[7]) != 11) return 0;
    out->Data1 = a; out->Data2 = (USHORT)b; out->Data3 = (USHORT)c;
    for (int i = 0; i < 8; i++) out->Data4[i] = (UCHAR)d[i];
    return 1;
}

static HRESULT factory(const wchar_t *cls, const GUID *iid, void **out)
{
    HSTRING h; HRESULT hr = WindowsCreateString(cls, (UINT32)wcslen(cls), &h);
    if (FAILED(hr)) return hr;
    hr = RoGetActivationFactory(h, iid, out);
    WindowsDeleteString(h);
    return hr;
}

/* Block until an IAsyncOperation finishes. */
static HRESULT wait_op(void *op, DWORD ms)
{
    void *info; HRESULT hr = qi(op, &IID_IAsyncInfo_, &info);
    if (FAILED(hr)) return hr;
    INT32 st = 0; DWORD t0 = GetTickCount();
    for (;;) {
        FN(info, AI_STATUS, GETI32_T)(info, &st);
        if (st != 0) break;
        if (GetTickCount() - t0 > ms) { FN(info, AI_CANCEL, HRESULT (WINAPI *)(void *))(info); rel(info); return HRESULT_FROM_WIN32(ERROR_TIMEOUT); }
        Sleep(5);
    }
    if (st == 1) hr = S_OK;
    else if (st == 3) { HRESULT e = E_FAIL; FN(info, AI_ERRORCODE, HRESULT (WINAPI *)(void *, HRESULT *))(info, &e); hr = e; }
    else hr = E_ABORT;
    rel(info);
    return hr;
}
static HRESULT op_ptr(void *op, DWORD ms, void **out) { *out = NULL; HRESULT hr = wait_op(op, ms); if (SUCCEEDED(hr)) hr = FN(op, OP_GETRESULTS, GETPTR_T)(op, out); rel(op); return hr; }
static HRESULT op_i32(void *op, DWORD ms, INT32 *out) { *out = -1; HRESULT hr = wait_op(op, ms); if (SUCCEEDED(hr)) hr = FN(op, OP_GETRESULTS, GETI32_T)(op, out); rel(op); return hr; }

/* ---------- delegates (event handlers) ---------- */
typedef struct { void **vtbl; const GUID *iid; } Delegate;
static HRESULT WINAPI d_qi(void *self, REFIID iid, void **out)
{
    Delegate *d = self;
    if (IsEqualGUID(iid, &IID_IUnknown_) || IsEqualGUID(iid, &IID_IAgileObject_) || IsEqualGUID(iid, d->iid)) { *out = self; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI d_addref(void *self) { (void)self; return 2; }  /* static objects */
static ULONG WINAPI d_release(void *self) { (void)self; return 1; }

static void utf8(HSTRING h, char *out, int n)
{
    UINT32 len = 0; const wchar_t *w = WindowsGetStringRawBuffer(h, &len);
    int k = WideCharToMultiByte(CP_UTF8, 0, w, (int)len, out, n - 1, NULL, NULL);
    out[k > 0 ? k : 0] = 0;
}

static HRESULT WINAPI on_received(void *self, void *sender, void *args)
{
    (void)self; (void)sender;
    UINT64 addr = 0; INT16 rssi = 0; char name[64] = ""; unsigned svc = 0;
    FN(args, RA_ADDRESS, HRESULT (WINAPI *)(void *, UINT64 *))(args, &addr);
    FN(args, RA_RSSI, HRESULT (WINAPI *)(void *, INT16 *))(args, &rssi);
    void *adv = NULL;
    if (SUCCEEDED(FN(args, RA_ADVERTISEMENT, GETPTR_T)(args, &adv)) && adv) {
        HSTRING h = NULL;
        if (SUCCEEDED(FN(adv, AD_LOCALNAME, HRESULT (WINAPI *)(void *, HSTRING *))(adv, &h)) && h) { utf8(h, name, sizeof name); WindowsDeleteString(h); }
        void *uuids = NULL; UINT32 nu = 0;
        if (SUCCEEDED(FN(adv, AD_SERVICEUUIDS, GETPTR_T)(adv, &uuids)) && uuids) {
            FN(uuids, VEC_SIZE, GETU32_T)(uuids, &nu);
            for (UINT32 k = 0; k < nu && k < 16; k++) {
                GUID g;
                if (FAILED(FN(uuids, VEC_GETAT, HRESULT (WINAPI *)(void *, UINT32, GUID *))(uuids, k, &g))) continue;
                if (memcmp(&g.Data2, &BASE_GUID.Data2, sizeof(GUID) - 4) != 0) continue;
                switch (g.Data1) {
                    case 0x1826: svc |= SV_FTMS; break; case 0x1814: svc |= SV_RSC; break;
                    case 0x1816: svc |= SV_CSC; break; case 0x1818: svc |= SV_POWER; break;
                    case 0x180D: svc |= SV_HR; break; case 0xFFF0: svc |= SV_FFF0; break;
                }
            }
            rel(uuids);
        }
        rel(adv);
    }
    EnterCriticalSection(&g_lock);
    int i;
    for (i = 0; i < g_ndev && g_devs[i].addr != addr; i++) {}
    if (i == g_ndev && g_ndev < MAXDEV) { g_ndev++; memset(&g_devs[i], 0, sizeof g_devs[i]); g_devs[i].addr = addr; }
    if (i < g_ndev) {
        g_devs[i].rssi = rssi; g_devs[i].seen = GetTickCount();
        if (name[0]) snprintf(g_devs[i].name, sizeof g_devs[i].name, "%s", name);
        g_devs[i].svc |= svc;
    }
    LeaveCriticalSection(&g_lock);
    return S_OK;
}

static HRESULT WINAPI on_changed(void *self, void *sender, void *args)
{
    (void)self;
    void *buf = NULL, *bba = NULL; UINT32 n = 0; BYTE *p = NULL; GUID id; int which = 0;
    if (SUCCEEDED(FN(sender, C_UUID, HRESULT (WINAPI *)(void *, GUID *))(sender, &id)))
        for (int i = 0; i < g_nnotify; i++) if (IsEqualGUID(&id, &g_nchar[i])) { which = i; break; }
    if (FAILED(FN(args, VC_VALUE, GETPTR_T)(args, &buf)) || !buf) return S_OK;
    FN(buf, B_LENGTH, GETU32_T)(buf, &n);
    if (SUCCEEDED(qi(buf, &IID_IBufferByteAccess_, &bba))) {
        FN(bba, BBA_BUFFER, HRESULT (WINAPI *)(void *, BYTE **))(bba, &p);
        if (p) {
            if (n > PKTMAX) n = PKTMAX;
            EnterCriticalSection(&g_lock);
            int next = (g_qtail + 1) % QCAP;
            if (next == g_qhead) g_dropped++;
            else { memcpy(g_q[g_qtail], p, n); g_qlen[g_qtail] = (int)n; g_qwhich[g_qtail] = which; g_qtail = next; }
            LeaveCriticalSection(&g_lock);
        }
        rel(bba);
    }
    rel(buf);
    return S_OK;
}

static void *recv_vtbl[] = { d_qi, d_addref, d_release, on_received };
static void *change_vtbl[] = { d_qi, d_addref, d_release, on_changed };
static Delegate g_recv_handler = { recv_vtbl, &IID_ReceivedHandler };
static Delegate g_change_handler = { change_vtbl, &IID_ValueChangedHandler };

/* ---------- scanning ---------- */
API const char *sb_last_error(void) { return g_err; }
API const char *sb_status_text(void) { return g_status; }
API int sb_state(void) { return (int)g_state; }

API int sb_scan_start(void)
{
    init(); ensure_ro();
    if (g_watcher) return 0;
    HSTRING h; const wchar_t *cls = L"Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher";
    HRESULT hr = WindowsCreateString(cls, (UINT32)wcslen(cls), &h);
    void *insp = NULL;
    if (SUCCEEDED(hr)) { hr = RoActivateInstance(h, (IInspectable **)&insp); WindowsDeleteString(h); }
    if (FAILED(hr)) { set_err("Couldn't create the Bluetooth scanner. Is Bluetooth on?", hr); return -1; }
    hr = qi(insp, &IID_IBLEAdvWatcher, &g_watcher); rel(insp);
    if (FAILED(hr)) { set_err("Bluetooth scanner interface missing", hr); return -1; }
    FN(g_watcher, W_PUT_SCANMODE, HRESULT (WINAPI *)(void *, INT32))(g_watcher, 1 /* Active: also gets names */);
    hr = FN(g_watcher, W_ADD_RECEIVED, HRESULT (WINAPI *)(void *, void *, EventRegistrationToken *))(g_watcher, &g_recv_handler, &g_recv_tok);
    if (FAILED(hr)) { set_err("Couldn't attach scan handler", hr); rel(g_watcher); g_watcher = NULL; return -1; }
    hr = FN(g_watcher, W_START, HRESULT (WINAPI *)(void *))(g_watcher);
    if (FAILED(hr)) { set_err("Couldn't start scanning. Is Bluetooth on?", hr); rel(g_watcher); g_watcher = NULL; return -1; }
    return 0;
}

API void sb_scan_stop(void)
{
    if (!g_watcher) return;
    ensure_ro();
    FN(g_watcher, W_STOP, HRESULT (WINAPI *)(void *))(g_watcher);
    FN(g_watcher, W_REMOVE_RECEIVED, HRESULT (WINAPI *)(void *, EventRegistrationToken))(g_watcher, g_recv_tok);
    rel(g_watcher); g_watcher = NULL;
}

/* Lines: "name\tAABBCCDDEEFF\trssi\tage_ms\tsvcflags\n" for every device seen. Returns count. */
API int sb_scan_list(char *out, int outlen)
{
    init();
    int used = 0, n;
    if (outlen > 0) out[0] = 0;
    EnterCriticalSection(&g_lock);
    n = g_ndev;
    DWORD now = GetTickCount();
    for (int i = 0; i < g_ndev && used < outlen; i++)
        used += snprintf(out + used, outlen - used, "%s\t%012llX\t%d\t%lu\t%u\n", g_devs[i].name,
                         (unsigned long long)g_devs[i].addr, g_devs[i].rssi, (unsigned long)(now - g_devs[i].seen), g_devs[i].svc);
    LeaveCriticalSection(&g_lock);
    return n;
}

/* ---------- connecting ---------- */
static void release_conn(void)
{
    for (int i = 0; i < MAXNOTIFY; i++) if (g_notify[i]) {
        FN(g_notify[i], C_REMOVE_CHANGED, HRESULT (WINAPI *)(void *, EventRegistrationToken))(g_notify[i], g_change_tok[i]);
        rel(g_notify[i]); g_notify[i] = NULL;
    }
    rel(g_write); g_write = NULL;
    void *cl;
    if (g_service) { if (SUCCEEDED(qi(g_service, &IID_IClosable_, &cl))) { FN(cl, CL_CLOSE, HRESULT (WINAPI *)(void *))(cl); rel(cl); } rel(g_service); g_service = NULL; }
    if (g_device) { if (SUCCEEDED(qi(g_device, &IID_IClosable_, &cl))) { FN(cl, CL_CLOSE, HRESULT (WINAPI *)(void *))(cl); rel(cl); } rel(g_device); g_device = NULL; }
}

static HRESULT get_char(void *svc3, const GUID *uuid, void **out)
{
    void *op = NULL, *res = NULL, *vec = NULL; INT32 st = -1; UINT32 n = 0;
    *out = NULL;
    HRESULT hr = FN(svc3, S3_CHARS_FOR_UUID_MODE, HRESULT (WINAPI *)(void *, GUID, INT32, void **))(svc3, *uuid, g_cache_mode, &op);
    if (SUCCEEDED(hr)) hr = op_ptr(op, 10000, &res);
    if (FAILED(hr) || !res) return FAILED(hr) ? hr : E_FAIL;
    FN(res, CR_STATUS, GETI32_T)(res, &st);
    if (st == 0 && SUCCEEDED(FN(res, CR_CHARS, GETPTR_T)(res, &vec)) && vec) {
        FN(vec, VV_SIZE, GETU32_T)(vec, &n);
        if (n > 0) FN(vec, VV_GETAT, HRESULT (WINAPI *)(void *, UINT32, void **))(vec, 0, out);
        rel(vec);
    }
    rel(res);
    if (st != 0) return E_FAIL;
    return *out ? S_OK : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

static const char *gatt_status(INT32 st)
{
    switch (st) { case 0: return "ok"; case 1: return "unreachable"; case 2: return "protocol error"; case 3: return "access denied"; default: return "unknown"; }
}

static DWORD WINAPI connect_thread(LPVOID p)
{
    (void)p;
    ensure_ro();
    HRESULT hr; void *statics = NULL, *op = NULL, *dev3 = NULL, *res = NULL, *vec = NULL, *svc3 = NULL;
    INT32 st = -1; UINT32 n = 0;

    set_status("Opening device...");
    hr = factory(L"Windows.Devices.Bluetooth.BluetoothLEDevice", &IID_IBLEDeviceStatics, &statics);
    if (SUCCEEDED(hr)) hr = FN(statics, DS_FROMADDRESS, HRESULT (WINAPI *)(void *, UINT64, void **))(statics, g_addr, &op);
    rel(statics);
    if (SUCCEEDED(hr)) hr = op_ptr(op, 15000, &g_device);
    if (FAILED(hr) || !g_device) { set_err("Couldn't open the device. Is it on and nearby?", FAILED(hr) ? hr : E_FAIL); goto fail; }

    hr = qi(g_device, &IID_IBLEDevice3, &dev3);
    if (FAILED(hr)) { set_err("Windows is too old (needs Windows 10 1703+)", hr); goto fail; }

    for (int attempt = 1; attempt <= 3; attempt++) {
        char msg[64]; snprintf(msg, sizeof msg, "Connecting and reading services (try %d of 3)...", attempt);
        set_status(msg);
        op = NULL; res = NULL; st = -1;
        hr = FN(dev3, D3_SERVICES_FOR_UUID_MODE, HRESULT (WINAPI *)(void *, GUID, INT32, void **))(dev3, g_svc, attempt == 1 ? g_cache_mode : 1, &op);
        if (SUCCEEDED(hr)) hr = op_ptr(op, 15000, &res);
        if (SUCCEEDED(hr) && res) {
            FN(res, SR_STATUS, GETI32_T)(res, &st);
            if (st == 0 && SUCCEEDED(FN(res, SR_SERVICES, GETPTR_T)(res, &vec)) && vec) {
                FN(vec, VV_SIZE, GETU32_T)(vec, &n);
                if (n > 0) FN(vec, VV_GETAT, HRESULT (WINAPI *)(void *, UINT32, void **))(vec, 0, &g_service);
                rel(vec); vec = NULL;
            }
            rel(res);
        }
        if (g_service) break;
        Sleep(1000);
    }
    rel(dev3);
    if (!g_service) {
        char m[160];
        if (FAILED(hr)) snprintf(m, sizeof m, "Couldn't read services. Close the phone app / turn phone Bluetooth off");
        else if (st != 0) snprintf(m, sizeof m, "Service lookup failed: %s. Close the phone app / turn phone Bluetooth off", gatt_status(st));
        else snprintf(m, sizeof m, "Device has no service with the requested UUID");
        set_err(m, FAILED(hr) ? hr : (HRESULT)st);
        goto fail;
    }

    set_status("Finding characteristics...");
    hr = qi(g_service, &IID_IGattDeviceService3, &svc3);
    if (FAILED(hr)) { set_err("GATT service interface missing", hr); goto fail; }
    for (int i = 0; i < g_nnotify; i++)
        if (FAILED(hr = get_char(svc3, &g_nchar[i], &g_notify[i]))) { set_err("Notify characteristic not found", hr); rel(svc3); goto fail; }
    if (g_has_w && FAILED(hr = get_char(svc3, &g_wchar, &g_write))) { set_err("Write characteristic not found", hr); rel(svc3); goto fail; }
    rel(svc3);

    if (g_write) {
        UINT32 props = 0;
        FN(g_write, C_PROPS, GETU32_T)(g_write, &props);
        g_write_noresp = (props & 0x4) != 0;
    }
    for (int i = 0; i < g_nnotify; i++) {
        set_status("Subscribing to notifications...");
        hr = FN(g_notify[i], C_ADD_CHANGED, HRESULT (WINAPI *)(void *, void *, EventRegistrationToken *))(g_notify[i], &g_change_handler, &g_change_tok[i]);
        if (FAILED(hr)) { set_err("Couldn't attach notification handler", hr); goto fail; }
        UINT32 props = 0;
        FN(g_notify[i], C_PROPS, GETU32_T)(g_notify[i], &props);
        INT32 cccd = (props & 0x10) ? 1 : 2; /* Notify, else Indicate */
        op = NULL; st = -1;
        hr = FN(g_notify[i], C_WRITE_CCCD, HRESULT (WINAPI *)(void *, INT32, void **))(g_notify[i], cccd, &op);
        if (SUCCEEDED(hr)) hr = op_i32(op, 10000, &st);
        if (FAILED(hr) || st != 0) {
            char m[96]; snprintf(m, sizeof m, "Subscribing failed: %s", FAILED(hr) ? "error" : gatt_status(st));
            set_err(m, FAILED(hr) ? hr : (HRESULT)st); goto fail;
        }
    }
    set_status("Connected");
    InterlockedExchange(&g_state, 2);
    return 0;
fail:
    release_conn();
    set_status("Failed");
    InterlockedExchange(&g_state, -1);
    return 1;
}

API void sb_close(void)
{
    init(); ensure_ro();
    if (g_thread) { WaitForSingleObject(g_thread, 20000); CloseHandle(g_thread); g_thread = NULL; }
    release_conn();
    EnterCriticalSection(&g_lock);
    g_qhead = g_qtail = g_dropped = 0;
    LeaveCriticalSection(&g_lock);
    InterlockedExchange(&g_state, 0);
}

/* Start connecting in the background. addr is 12 hex digits; notify_uuids is a
 * comma-separated list (up to 4, may be empty). Poll sb_state(). */
API int sb_open(const char *addr_hex, const char *service, const char *notify_uuid, const char *write_uuid)
{
    init(); ensure_ro();
    sb_close();
    g_err[0] = 0;
    g_addr = strtoull(addr_hex, NULL, 16);
    if (!g_addr || !parse_uuid(service, &g_svc)) { snprintf(g_err, sizeof g_err, "bad address or service uuid"); return -1; }
    g_nnotify = 0;
    if (notify_uuid) {
        char list[256]; snprintf(list, sizeof list, "%s", notify_uuid);
        for (char *t = strtok(list, ","); t && g_nnotify < MAXNOTIFY; t = strtok(NULL, ","))
            if (*t && parse_uuid(t, &g_nchar[g_nnotify])) g_nnotify++;
    }
    g_has_w = write_uuid && write_uuid[0] && parse_uuid(write_uuid, &g_wchar);
    InterlockedExchange(&g_state, 1);
    g_thread = CreateThread(NULL, 0, connect_thread, NULL, 0, NULL);
    if (!g_thread) { InterlockedExchange(&g_state, -1); set_err("CreateThread", HRESULT_FROM_WIN32(GetLastError())); return -1; }
    return 0;
}

API int sb_write(const unsigned char *data, int len)
{
    ensure_ro();
    if (g_state != 2 || !g_write) { snprintf(g_err, sizeof g_err, "not connected"); return -1; }
    if (len <= 0 || len > PKTMAX) return -2;
    HRESULT hr = S_OK;
    if (!g_buffactory) hr = factory(L"Windows.Storage.Streams.Buffer", &IID_IBufferFactory_, &g_buffactory);
    if (FAILED(hr)) { set_err("Buffer factory", hr); return -3; }
    void *buf = NULL, *bba = NULL, *op = NULL; BYTE *p = NULL; INT32 st = -1;
    hr = FN(g_buffactory, BF_CREATE, HRESULT (WINAPI *)(void *, UINT32, void **))(g_buffactory, (UINT32)len, &buf);
    if (FAILED(hr)) { set_err("Buffer create", hr); return -3; }
    if (SUCCEEDED(qi(buf, &IID_IBufferByteAccess_, &bba))) { FN(bba, BBA_BUFFER, HRESULT (WINAPI *)(void *, BYTE **))(bba, &p); if (p) memcpy(p, data, len); rel(bba); }
    FN(buf, B_PUT_LENGTH, HRESULT (WINAPI *)(void *, UINT32))(buf, (UINT32)len);
    hr = FN(g_write, C_WRITE_OPT, HRESULT (WINAPI *)(void *, void *, INT32, void **))(g_write, buf, g_write_noresp ? 1 : 0, &op);
    rel(buf);
    if (SUCCEEDED(hr)) hr = op_i32(op, 2000, &st);
    if (FAILED(hr) || st != 0) {
        char m[64]; snprintf(m, sizeof m, "Write failed: %s", FAILED(hr) ? "error" : gatt_status(st));
        set_err(m, FAILED(hr) ? hr : (HRESULT)st);
        return -4;
    }
    return 0;
}

/* Pop one queued notification. Returns its length, 0 if none. */
API int sb_read(unsigned char *buf, int maxlen)
{
    init();
    int n = 0;
    EnterCriticalSection(&g_lock);
    if (g_qhead != g_qtail) {
        n = g_qlen[g_qhead] < maxlen ? g_qlen[g_qhead] : maxlen;
        memcpy(buf, g_q[g_qhead], n);
        g_qhead = (g_qhead + 1) % QCAP;
    }
    LeaveCriticalSection(&g_lock);
    return n;
}

/* Like sb_read, also returns which notify characteristic (index into the
 * sb_open list) the packet came from. */
API int sb_read_ex(unsigned char *buf, int maxlen, int *which)
{
    init();
    int n = 0;
    EnterCriticalSection(&g_lock);
    if (g_qhead != g_qtail) {
        n = g_qlen[g_qhead] < maxlen ? g_qlen[g_qhead] : maxlen;
        memcpy(buf, g_q[g_qhead], n);
        if (which) *which = g_qwhich[g_qhead];
        g_qhead = (g_qhead + 1) % QCAP;
    }
    LeaveCriticalSection(&g_lock);
    return n;
}

API int sb_dropped(void) { return g_dropped; }

/* 0 = use Windows' cached services (fast reconnect), 1 = always read from the device. */
API void sb_set_cache_mode(int uncached) { g_cache_mode = uncached ? 1 : 0; }

/* ---------- device explorer (read-only) ----------
 * Lists every service and characteristic of a device, reads the readable ones,
 * and subscribes to the notifying ones for a few seconds to capture samples.
 * Never writes a value to the device (only the standard notify/indicate
 * subscription descriptor). Output is plain text lines, fetched with
 * sb_explore_text():
 *   service <uuid>
 *   char <uuid> props <hex>
 *   read <uuid> <hex bytes> | read <uuid> failed <status>
 *   sub <uuid> ok|failed
 *   notify <uuid> <hex bytes>
 *   error <message>
 */
enum {
    D3_SERVICES_MODE = 9,      /* IBluetoothLEDevice3::GetGattServicesWithCacheModeAsync */
    S_UUID = 9,                /* IGattDeviceService::Uuid */
    S3_CHARS_MODE = 12,        /* IGattDeviceService3::GetCharacteristicsWithCacheModeAsync */
    C_READ_MODE = 15,
    RR_STATUS = 6, RR_VALUE = 7,
};
#define EXMAX 65536
#define EXCHARS 48
static char g_ex[EXMAX];
static int g_exlen;
static volatile LONG g_ex_state;      /* 0 idle, 1 running, 2 done, -1 failed */
static HANDLE g_ex_thread;
static UINT64 g_ex_addr;
static DWORD g_ex_listen_ms;
static GUID g_ex_ids[EXCHARS];
static int g_ex_counts[EXCHARS], g_ex_n;

static void ex_line(const char *fmt, ...)
{
    char tmp[1200];
    va_list ap; va_start(ap, fmt); int n = vsnprintf(tmp, sizeof tmp - 2, fmt, ap); va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof tmp - 2) n = sizeof tmp - 2;
    tmp[n++] = '\n';
    EnterCriticalSection(&g_lock);
    if (g_exlen + n < EXMAX) { memcpy(g_ex + g_exlen, tmp, n); g_exlen += n; g_ex[g_exlen] = 0; }
    LeaveCriticalSection(&g_lock);
}

static void guid_str(const GUID *g, char *out)
{
    sprintf(out, "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x", (unsigned long)g->Data1, g->Data2, g->Data3,
            g->Data4[0], g->Data4[1], g->Data4[2], g->Data4[3], g->Data4[4], g->Data4[5], g->Data4[6], g->Data4[7]);
}

static void hex_str(const BYTE *p, UINT32 n, char *out, int outlen)
{
    int k = 0;
    for (UINT32 i = 0; i < n && k + 4 < outlen; i++) k += sprintf(out + k, i ? " %02X" : "%02X", p[i]);
    out[k] = 0;
}

/* Copy an IBuffer's bytes as hex. */
static void buffer_hex(void *buf, char *out, int outlen)
{
    void *bba = NULL; UINT32 n = 0; BYTE *p = NULL;
    out[0] = 0;
    FN(buf, B_LENGTH, GETU32_T)(buf, &n);
    if (SUCCEEDED(qi(buf, &IID_IBufferByteAccess_, &bba))) {
        FN(bba, BBA_BUFFER, HRESULT (WINAPI *)(void *, BYTE **))(bba, &p);
        if (p) hex_str(p, n, out, outlen);
        rel(bba);
    }
}

static HRESULT WINAPI on_explore_changed(void *self, void *sender, void *args)
{
    (void)self;
    GUID id; char u[40], hx[1100]; void *buf = NULL;
    if (FAILED(FN(sender, C_UUID, HRESULT (WINAPI *)(void *, GUID *))(sender, &id))) return S_OK;
    int i, keep = 0;
    EnterCriticalSection(&g_lock);
    for (i = 0; i < g_ex_n && !IsEqualGUID(&g_ex_ids[i], &id); i++) {}
    if (i < g_ex_n && g_ex_counts[i] < 8) { g_ex_counts[i]++; keep = 1; }
    LeaveCriticalSection(&g_lock);
    if (!keep) return S_OK;
    if (SUCCEEDED(FN(args, VC_VALUE, GETPTR_T)(args, &buf)) && buf) {
        buffer_hex(buf, hx, sizeof hx);
        guid_str(&id, u);
        ex_line("notify %s %s", u, hx);
        rel(buf);
    }
    return S_OK;
}
static void *explore_vtbl[] = { d_qi, d_addref, d_release, on_explore_changed };
static Delegate g_explore_handler = { explore_vtbl, &IID_ValueChangedHandler };

static DWORD WINAPI explore_thread(LPVOID p)
{
    (void)p;
    ensure_ro();
    void *statics = NULL, *op = NULL, *dev = NULL, *dev3 = NULL, *res = NULL, *svcs = NULL;
    void *subs[EXCHARS]; EventRegistrationToken toks[EXCHARS]; int nsub = 0;
    void *open_svcs[64]; int nsvc_open = 0;
    INT32 st = -1; UINT32 nsvc = 0; HRESULT hr; char u[40], hx[1100];

    hr = factory(L"Windows.Devices.Bluetooth.BluetoothLEDevice", &IID_IBLEDeviceStatics, &statics);
    if (SUCCEEDED(hr)) hr = FN(statics, DS_FROMADDRESS, HRESULT (WINAPI *)(void *, UINT64, void **))(statics, g_ex_addr, &op);
    rel(statics);
    if (SUCCEEDED(hr)) hr = op_ptr(op, 15000, &dev);
    if (FAILED(hr) || !dev) { ex_line("error couldn't open device (0x%08lX)", (unsigned long)hr); goto done_fail; }
    if (FAILED(qi(dev, &IID_IBLEDevice3, &dev3))) { ex_line("error Windows too old"); goto done_fail; }

    for (int attempt = 0; attempt < 3 && !svcs; attempt++) {
        op = NULL; res = NULL; st = -1;
        hr = FN(dev3, D3_SERVICES_MODE, HRESULT (WINAPI *)(void *, INT32, void **))(dev3, 1 /* Uncached */, &op);
        if (SUCCEEDED(hr)) hr = op_ptr(op, 15000, &res);
        if (SUCCEEDED(hr) && res) {
            FN(res, SR_STATUS, GETI32_T)(res, &st);
            if (st == 0) FN(res, SR_SERVICES, GETPTR_T)(res, &svcs);
            rel(res);
        }
        if (!svcs) Sleep(1000);
    }
    rel(dev3);
    if (!svcs) { ex_line("error couldn't read services: %s (0x%08lX). Close other apps using the device", gatt_status(st), (unsigned long)hr); goto done_fail; }
    FN(svcs, VV_SIZE, GETU32_T)(svcs, &nsvc);

    for (UINT32 s = 0; s < nsvc && s < 64; s++) {
        void *svc = NULL, *svc3 = NULL, *cres = NULL, *chars = NULL; GUID sid; UINT32 nch = 0;
        FN(svcs, VV_GETAT, HRESULT (WINAPI *)(void *, UINT32, void **))(svcs, s, &svc);
        if (!svc) continue;
        open_svcs[nsvc_open++] = svc;
        FN(svc, S_UUID, HRESULT (WINAPI *)(void *, GUID *))(svc, &sid);
        guid_str(&sid, u); ex_line("service %s", u);
        if (FAILED(qi(svc, &IID_IGattDeviceService3, &svc3))) continue;
        op = NULL; st = -1;
        hr = FN(svc3, S3_CHARS_MODE, HRESULT (WINAPI *)(void *, INT32, void **))(svc3, 1, &op);
        if (SUCCEEDED(hr)) hr = op_ptr(op, 10000, &cres);
        rel(svc3);
        if (FAILED(hr) || !cres) { ex_line("error characteristics of %s unreadable (0x%08lX)", u, (unsigned long)hr); continue; }
        FN(cres, CR_STATUS, GETI32_T)(cres, &st);
        if (st == 0) FN(cres, CR_CHARS, GETPTR_T)(cres, &chars);
        rel(cres);
        if (!chars) { ex_line("error characteristics of %s: %s", u, gatt_status(st)); continue; }
        FN(chars, VV_SIZE, GETU32_T)(chars, &nch);
        for (UINT32 c = 0; c < nch; c++) {
            void *ch = NULL; GUID cid; UINT32 props = 0;
            FN(chars, VV_GETAT, HRESULT (WINAPI *)(void *, UINT32, void **))(chars, c, &ch);
            if (!ch) continue;
            FN(ch, C_UUID, HRESULT (WINAPI *)(void *, GUID *))(ch, &cid);
            FN(ch, C_PROPS, GETU32_T)(ch, &props);
            guid_str(&cid, u); ex_line("char %s props %02X", u, props);
            if (props & 0x02) {
                void *rr = NULL, *val = NULL; INT32 rs = -1;
                op = NULL;
                hr = FN(ch, C_READ_MODE, HRESULT (WINAPI *)(void *, INT32, void **))(ch, 1, &op);
                if (SUCCEEDED(hr)) hr = op_ptr(op, 5000, &rr);
                if (SUCCEEDED(hr) && rr) {
                    FN(rr, RR_STATUS, GETI32_T)(rr, &rs);
                    if (rs == 0 && SUCCEEDED(FN(rr, RR_VALUE, GETPTR_T)(rr, &val)) && val) { buffer_hex(val, hx, sizeof hx); ex_line("read %s %s", u, hx); rel(val); }
                    else ex_line("read %s failed %s", u, gatt_status(rs));
                    rel(rr);
                } else ex_line("read %s failed (0x%08lX)", u, (unsigned long)hr);
            }
            if ((props & 0x30) && nsub < EXCHARS) {
                EnterCriticalSection(&g_lock);
                g_ex_ids[g_ex_n] = cid; g_ex_counts[g_ex_n] = 0; g_ex_n++;
                LeaveCriticalSection(&g_lock);
                hr = FN(ch, C_ADD_CHANGED, HRESULT (WINAPI *)(void *, void *, EventRegistrationToken *))(ch, &g_explore_handler, &toks[nsub]);
                INT32 ws = -1;
                if (SUCCEEDED(hr)) {
                    op = NULL;
                    hr = FN(ch, C_WRITE_CCCD, HRESULT (WINAPI *)(void *, INT32, void **))(ch, (props & 0x10) ? 1 : 2, &op);
                    if (SUCCEEDED(hr)) hr = op_i32(op, 5000, &ws);
                }
                ex_line("sub %s %s", u, SUCCEEDED(hr) && ws == 0 ? "ok" : "failed");
                FN(ch, 1, ULONG (WINAPI *)(void *))(ch); /* AddRef: keep it for the listen window */
                subs[nsub++] = ch;
            }
            rel(ch);
        }
        rel(chars);
    }
    rel(svcs);

    ex_line("listening %lu", (unsigned long)g_ex_listen_ms);
    Sleep(g_ex_listen_ms);
    for (int i = 0; i < nsub; i++) {
        FN(subs[i], C_REMOVE_CHANGED, HRESULT (WINAPI *)(void *, EventRegistrationToken))(subs[i], toks[i]);
        rel(subs[i]);
    }
    for (int i = 0; i < nsvc_open; i++) {
        void *cl;
        if (SUCCEEDED(qi(open_svcs[i], &IID_IClosable_, &cl))) { FN(cl, CL_CLOSE, HRESULT (WINAPI *)(void *))(cl); rel(cl); }
        rel(open_svcs[i]);
    }
    { void *cl; if (SUCCEEDED(qi(dev, &IID_IClosable_, &cl))) { FN(cl, CL_CLOSE, HRESULT (WINAPI *)(void *))(cl); rel(cl); } }
    rel(dev);
    ex_line("done");
    InterlockedExchange(&g_ex_state, 2);
    return 0;
done_fail:
    if (dev) rel(dev);
    InterlockedExchange(&g_ex_state, -1);
    return 1;
}

/* Start exploring the device at addr (12 hex digits); listen_ms for notifications. */
API int sb_explore(const char *addr_hex, int listen_ms)
{
    init(); ensure_ro();
    if (g_ex_state == 1) return -1;
    if (g_ex_thread) { WaitForSingleObject(g_ex_thread, 30000); CloseHandle(g_ex_thread); g_ex_thread = NULL; }
    g_ex_addr = strtoull(addr_hex, NULL, 16);
    if (!g_ex_addr) return -2;
    g_ex_listen_ms = listen_ms > 0 ? (DWORD)listen_ms : 8000;
    EnterCriticalSection(&g_lock);
    g_exlen = 0; g_ex[0] = 0; g_ex_n = 0;
    LeaveCriticalSection(&g_lock);
    InterlockedExchange(&g_ex_state, 1);
    g_ex_thread = CreateThread(NULL, 0, explore_thread, NULL, 0, NULL);
    if (!g_ex_thread) { InterlockedExchange(&g_ex_state, -1); return -3; }
    return 0;
}

API int sb_explore_state(void) { return (int)g_ex_state; }

/* Copy the explorer output so far. Returns its length. */
API int sb_explore_text(char *out, int outlen)
{
    init();
    EnterCriticalSection(&g_lock);
    int n = g_exlen < outlen - 1 ? g_exlen : outlen - 1;
    memcpy(out, g_ex, n); out[n] = 0;
    LeaveCriticalSection(&g_lock);
    return n;
}

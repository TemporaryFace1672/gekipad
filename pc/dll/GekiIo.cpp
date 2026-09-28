// GekiIo.dll: implements segatools' mu3io + aimeio APIs for ONGEKI by reading a small shared-memory block that
// GekiBridge.exe (a separate process) fills in from the iPad. This mirrors the "Brokenithm"-style approach used for
// CHUNITHM: the DLL is loaded in-process by the game (via segatools' [mu3io]/[aimeio] path= config) and never talks
// to the iPad itself; the bridge .exe owns the USB link and just writes into shared memory.
//
// Exact API verified against djhackersdev/segatools' mu3io.h and aimeio.h, and cross-checked against a real
// ONGEKI ReFresh 1.51.00 install's segatools.ini/mu3.ini/start.bat (game=mu3.exe, hook=mu3hook.dll,
// [mu3io]/[aimeio] path= are read exactly as implemented here; confirmed via mu3hook/mu3-dll.c that a non-empty
// path= fully replaces the built-in mu3_io_* implementation, all five functions at once).
//
// Coin deliberately has NO code here: mu3io.h has no coin entry point, and mu3hook/io4.c shows coin/test/service
// keyboard input is a *separate*, always-on io4-board-level hook (GetAsyncKeyState based) that isn't part of the
// mu3io.h surface at all - so GekiBridge.exe injects the coin key directly, the same way this project's maimai
// bridge does, rather than duplicating that logic in here.
//
// Aime card id format: confirmed via djhackersdev/segatools' iccard/aime.c (aime_card_populate) that the 10-byte
// luid is BCD (each nibble a decimal digit 0-9) - i.e. the 20 decimal digits from aime.txt packed two per byte,
// NOT hex. A real aime.txt was checked ("89013861175251191402") and packs cleanly this way.
//
// STILL NEEDS CONFIRMING live: whether the game actually reads test/service through mu3_io_get_opbtns once this
// DLL is active (should, per mu3-dll.c, but wasn't observable without the game running), and the exact lever
// range/centre the game's own calibration screen expects.

#include <windows.h>
#include <stdint.h>
#include <string.h>

#ifndef S_OK
#define S_OK ((HRESULT)0L)
#endif
#ifndef S_FALSE
#define S_FALSE ((HRESULT)1L)
#endif

// ---- mu3io.h (inlined; see header comment for source) ----
enum {
    MU3_IO_OPBTN_TEST = 0x01,
    MU3_IO_OPBTN_SERVICE = 0x02,
};
enum {
    MU3_IO_GAMEBTN_1 = 0x01,
    MU3_IO_GAMEBTN_2 = 0x02,
    MU3_IO_GAMEBTN_3 = 0x04,
    MU3_IO_GAMEBTN_SIDE = 0x08,
    MU3_IO_GAMEBTN_MENU = 0x10,
};

#pragma pack(push, 1)
struct GekiPadShared {
    uint32_t magic;        // 'GKPD'
    uint8_t  version;      // 1
    int16_t  lever;        // -32768..32767, 0 = centre
    uint8_t  leftBtn;       // MU3_IO_GAMEBTN_* bits
    uint8_t  rightBtn;
    uint8_t  opBtn;         // MU3_IO_OPBTN_* bits (test/service - NOT coin, see header comment)
    uint8_t  reserved;      // was coin; kept so the struct layout matches GekiBridge.exe's copy exactly
    uint8_t  cardScan;      // 1 while the iPad's CARD button is held
    uint8_t  aimeLuid[10];  // classic Aime card id (BCD), valid while cardScan = 1
    uint8_t  connected;     // 1 while the bridge has an iPad linked
};
#pragma pack(pop)

static const uint32_t kMagic = 0x44504B47u; // "GKPD" little-endian
static const wchar_t *kMapName = L"Local\\GekiPadShared";

static HANDLE g_map = NULL;
static GekiPadShared *g_shared = NULL;
static CRITICAL_SECTION g_lock;
static bool g_lockInit = false;

static void EnsureShared() {
    if (g_shared) return;
    if (!g_lockInit) { InitializeCriticalSection(&g_lock); g_lockInit = true; }
    EnterCriticalSection(&g_lock);
    if (!g_shared) {
        g_map = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(GekiPadShared), kMapName);
        if (g_map) {
            g_shared = (GekiPadShared *)MapViewOfFile(g_map, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(GekiPadShared));
            if (g_shared && g_shared->magic != kMagic) {
                // freshly created (or stale from a crashed process) - reset to a safe idle state
                memset(g_shared, 0, sizeof(GekiPadShared));
                g_shared->magic = kMagic;
                g_shared->version = 1;
            }
        }
    }
    LeaveCriticalSection(&g_lock);
}

extern "C" {

__declspec(dllexport) uint16_t mu3_io_get_api_version(void) { return 0x0100; }

__declspec(dllexport) HRESULT mu3_io_init(void) {
    EnsureShared();
    return g_shared ? S_OK : E_FAIL;
}

__declspec(dllexport) HRESULT mu3_io_poll(void) {
    EnsureShared();
    return S_OK;
}

__declspec(dllexport) void mu3_io_get_opbtns(uint8_t *opbtn) {
    *opbtn = g_shared ? g_shared->opBtn : 0;
}

__declspec(dllexport) void mu3_io_get_gamebtns(uint8_t *left, uint8_t *right) {
    *left = g_shared ? g_shared->leftBtn : 0;
    *right = g_shared ? g_shared->rightBtn : 0;
}

__declspec(dllexport) void mu3_io_get_lever(int16_t *pos) {
    *pos = g_shared ? g_shared->lever : 0;
}

__declspec(dllexport) uint16_t aime_io_get_api_version(void) { return 0x0100; }

__declspec(dllexport) HRESULT aime_io_init(void) {
    EnsureShared();
    return g_shared ? S_OK : E_FAIL;
}

__declspec(dllexport) HRESULT aime_io_nfc_poll(uint8_t unit_no) {
    (void)unit_no;
    EnsureShared();
    return S_OK;
}

__declspec(dllexport) HRESULT aime_io_nfc_get_aime_id(uint8_t unit_no, uint8_t *luid, size_t luid_size) {
    (void)unit_no;
    if (!g_shared || !g_shared->cardScan || luid_size < 10) return S_FALSE;
    memcpy(luid, g_shared->aimeLuid, 10);
    return S_OK;
}

__declspec(dllexport) HRESULT aime_io_nfc_get_felica_id(uint8_t unit_no, uint64_t *IDm) {
    // Not implemented: this project only sends the classic BCD luid. The real install checked uses a plain
    // decimal aime.txt, which is the classic-card path, so this should not be needed - but flagging it in case
    // your card/setup turns out to want a FeliCa IDm instead.
    (void)unit_no; (void)IDm;
    return S_FALSE;
}

__declspec(dllexport) void aime_io_led_set_color(uint8_t unit_no, uint8_t r, uint8_t g, uint8_t b) {
    (void)unit_no; (void)r; (void)g; (void)b; // no real card-reader lighting to drive
}

} // extern "C"

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_DETACH) {
        if (g_shared) UnmapViewOfFile(g_shared);
        if (g_map) CloseHandle(g_map);
    }
    return TRUE;
}

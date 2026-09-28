// GekiIo.dll: implements segatools' mu3io + aimeio APIs for ONGEKI by reading a small shared-memory block that
// GekiBridge.exe (a separate process) fills in from the iPad. This mirrors the "Brokenithm"-style approach used for
// CHUNITHM: the DLL is loaded in-process by the game (via segatools' [mu3io]/[aimeio] path= config) and never talks
// to the iPad itself; the bridge .exe owns the USB link and just writes into shared memory.
//
// Exact API verified against djhackersdev/segatools' mu3io.h and aimeio.h (fetched 2026-09-28):
//   mu3_io_get_api_version / mu3_io_init / mu3_io_poll / mu3_io_get_opbtns / mu3_io_get_gamebtns / mu3_io_get_lever
//   aime_io_get_api_version / aime_io_init / aime_io_nfc_poll / aime_io_nfc_get_aime_id /
//   aime_io_nfc_get_felica_id / aime_io_led_set_color
// Coin is NOT part of mu3io.h (confirmed - it's handled elsewhere in the segatools stack, commonly a keyboard key),
// so this DLL injects a configurable key press instead, the same low-risk approach used for maimai/chuni.
//
// NEEDS CONFIRMING against a real ONGEKI install (no test hardware/game available while writing this):
//   - the exact [mu3io]/[aimeio]/hook ini section names for your segatools fork
//   - the game's window title (WindowTitle= in gekipad.cfg; defaults to a guess)
//   - the coin key your loader actually expects (CoinKey= in gekipad.cfg)
//   - the Aime card ID format your setup wants (this DLL sends the classic 10-byte luid; FeliCa IDm is not sent)

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef S_OK
#define S_OK ((HRESULT)0L)
#endif
#ifndef S_FALSE
#define S_FALSE ((HRESULT)1L)
#endif

// ---- mu3io.h (inlined; see comment above for source) ----
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
    uint8_t  opBtn;         // MU3_IO_OPBTN_* bits (test/service)
    uint8_t  coinHeld;      // 1 while the iPad's COIN button is held
    uint8_t  cardScan;      // 1 while the iPad's CARD button is held
    uint8_t  aimeLuid[10];  // classic Aime card id, valid while cardScan = 1
    uint8_t  connected;     // 1 while the bridge has an iPad linked
};
#pragma pack(pop)

static const uint32_t kMagic = 0x44504B47u; // "GKPD" little-endian
static const wchar_t *kMapName = L"Local\\GekiPadShared";

static HANDLE g_map = NULL;
static GekiPadShared *g_shared = NULL;
static CRITICAL_SECTION g_lock;
static bool g_lockInit = false;

static wchar_t g_windowTitle[128] = L"MU3"; // confirm against the real game window title
static int g_coinKey = 0x72;                 // VK_F3, matches the maimai coin key convention
static bool g_anyWindow = false;

static HMODULE g_hModule = NULL;

static void LoadConfig() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(g_hModule, path, MAX_PATH);
    wchar_t *slash = wcsrchr(path, L'\\');
    if (slash) *(slash + 1) = 0;
    wcscat_s(path, MAX_PATH, L"gekipad.cfg");
    FILE *f = _wfopen(path, L"r, ccs=UTF-8");
    if (!f) return;
    wchar_t line[256];
    while (fgetws(line, 256, f)) {
        wchar_t *eq = wcschr(line, L'=');
        if (!eq) continue;
        *eq = 0;
        wchar_t *val = eq + 1;
        size_t vlen = wcslen(val);
        while (vlen > 0 && (val[vlen - 1] == L'\n' || val[vlen - 1] == L'\r' || val[vlen - 1] == L' ')) val[--vlen] = 0;
        if (wcscmp(line, L"WindowTitle") == 0) wcsncpy_s(g_windowTitle, 128, val, _TRUNCATE);
        else if (wcscmp(line, L"CoinKey") == 0) g_coinKey = wcstol(val, NULL, 0);
        else if (wcscmp(line, L"AnyWindow") == 0) g_anyWindow = (wcscmp(val, L"1") == 0);
    }
    fclose(f);
}

static void EnsureShared() {
    if (g_shared) return;
    if (!g_lockInit) { InitializeCriticalSection(&g_lock); g_lockInit = true; }
    EnterCriticalSection(&g_lock);
    if (!g_shared) {
        LoadConfig();
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

static bool GameFocused() {
    if (g_anyWindow) return true;
    HWND h = GetForegroundWindow();
    wchar_t buf[128] = {0};
    GetWindowTextW(h, buf, 128);
    return wcsstr(buf, g_windowTitle) != NULL;
}

// Coin has no mu3io entry point, so we inject a key press instead - only while the game window is in front, so this
// can never leak keystrokes into another application. Level-triggered on shared->coinHeld, like the other segatools
// controllers in this project (maimai/chuni) that key-inject their coin button the same way.
static void PollCoin() {
    static bool held = false;
    bool want = g_shared && g_shared->coinHeld != 0;
    if (want == held) return;
    if (want && !GameFocused()) return; // try again next poll; never presses into a background window
    held = want;
    BYTE vk = (BYTE)g_coinKey;
    keybd_event(vk, (BYTE)MapVirtualKeyW(vk, 0), want ? 0 : KEYEVENTF_KEYUP, 0);
}

extern "C" {

__declspec(dllexport) uint16_t mu3_io_get_api_version(void) { return 0x0100; }

__declspec(dllexport) HRESULT mu3_io_init(void) {
    EnsureShared();
    return g_shared ? S_OK : E_FAIL;
}

__declspec(dllexport) HRESULT mu3_io_poll(void) {
    EnsureShared();
    if (g_shared) PollCoin();
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
    // Not implemented: this project only sends the classic 10-byte luid. Confirm which your card/setup needs.
    (void)unit_no; (void)IDm;
    return S_FALSE;
}

__declspec(dllexport) void aime_io_led_set_color(uint8_t unit_no, uint8_t r, uint8_t g, uint8_t b) {
    (void)unit_no; (void)r; (void)g; (void)b; // no real card-reader lighting to drive
}

} // extern "C"

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hModule = (HMODULE)hinst;
    }
    if (reason == DLL_PROCESS_DETACH) {
        if (g_shared) UnmapViewOfFile(g_shared);
        if (g_map) CloseHandle(g_map);
    }
    return TRUE;
}

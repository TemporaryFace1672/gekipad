// Standalone smoke test: writes the shared-memory block the same way GekiBridge.exe will, then loads GekiIo.dll and
// calls its exports exactly like segatools would, and checks the values round-trip correctly. Not shipped.
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#pragma pack(push, 1)
struct GekiPadShared {
    uint32_t magic;
    uint8_t  version;
    int16_t  lever;
    uint8_t  leftBtn, rightBtn, opBtn, reserved, cardScan;
    uint8_t  aimeLuid[10];
    uint8_t  connected;
};
#pragma pack(pop)

typedef uint16_t (*ver_fn)(void);
typedef HRESULT (*init_fn)(void);
typedef HRESULT (*poll_fn)(void);
typedef void (*opbtn_fn)(uint8_t*);
typedef void (*gamebtn_fn)(uint8_t*, uint8_t*);
typedef void (*lever_fn)(int16_t*);
typedef HRESULT (*aime_id_fn)(uint8_t, uint8_t*, size_t);

int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } else { printf("ok:   %s\n", msg); } } while(0)

int main(int argc, char **argv) {
    bool readOnly = argc > 1 && strcmp(argv[1], "--readonly") == 0;
    HANDLE map = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(GekiPadShared), L"Local\\GekiPadShared");
    if (!map) { printf("CreateFileMapping failed: %lu\n", GetLastError()); return 1; }
    GekiPadShared *sh = (GekiPadShared*)MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(GekiPadShared));
    if (!readOnly) {
        memset(sh, 0, sizeof(*sh));
        sh->magic = 0x44504B47u; sh->version = 1;
        sh->lever = -12345;
        sh->leftBtn = 0x01 | 0x08;   // btn1 + side
        sh->rightBtn = 0x04 | 0x10;  // btn3 + menu
        sh->opBtn = 0x02;            // service
        sh->cardScan = 1;
        for (int i = 0; i < 10; i++) sh->aimeLuid[i] = (uint8_t)(0xA0 + i);
    } else {
        printf("readonly mode: attached to existing shared memory, not writing test values\n");
        printf("current: magic=0x%08x lever=%d left=0x%02x right=0x%02x op=0x%02x card=%d connected=%d\n",
            sh->magic, sh->lever, sh->leftBtn, sh->rightBtn, sh->opBtn, sh->cardScan, sh->connected);
    }

    HMODULE dll = LoadLibraryW(L"GekiIo.dll");
    if (!dll) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }

    ver_fn mu3_ver = (ver_fn)GetProcAddress(dll, "mu3_io_get_api_version");
    init_fn mu3_init = (init_fn)GetProcAddress(dll, "mu3_io_init");
    poll_fn mu3_poll = (poll_fn)GetProcAddress(dll, "mu3_io_poll");
    opbtn_fn get_op = (opbtn_fn)GetProcAddress(dll, "mu3_io_get_opbtns");
    gamebtn_fn get_game = (gamebtn_fn)GetProcAddress(dll, "mu3_io_get_gamebtns");
    lever_fn get_lever = (lever_fn)GetProcAddress(dll, "mu3_io_get_lever");
    ver_fn aime_ver = (ver_fn)GetProcAddress(dll, "aime_io_get_api_version");
    init_fn aime_init = (init_fn)GetProcAddress(dll, "aime_io_init");
    aime_id_fn get_aime = (aime_id_fn)GetProcAddress(dll, "aime_io_nfc_get_aime_id");

    CHECK(mu3_ver && mu3_init && mu3_poll && get_op && get_game && get_lever && aime_ver && aime_init && get_aime, "all exports resolved");
    if (fails) return 1;

    printf("mu3 api version: 0x%04x\n", mu3_ver());
    CHECK(mu3_init() == S_OK, "mu3_io_init");
    CHECK(aime_init() == S_OK, "aime_io_init");
    CHECK(mu3_poll() == S_OK, "mu3_io_poll");

    uint8_t op = 0xFF; get_op(&op);
    uint8_t left = 0, right = 0; get_game(&left, &right);
    int16_t lever = 0; get_lever(&lever);
    uint8_t luid[10] = {0};
    HRESULT hr = get_aime(0, luid, 10);

    if (!readOnly) {
        CHECK(op == 0x02, "opbtn == SERVICE");
        CHECK(left == (0x01 | 0x08), "left gamebtn == BTN1|SIDE");
        CHECK(right == (0x04 | 0x10), "right gamebtn == BTN3|MENU");
        CHECK(lever == -12345, "lever == -12345");
        CHECK(hr == S_OK, "aime_io_nfc_get_aime_id returns S_OK while cardScan=1");
        bool luidOk = true;
        for (int i = 0; i < 10; i++) if (luid[i] != (uint8_t)(0xA0 + i)) luidOk = false;
        CHECK(luidOk, "luid bytes match");

        sh->cardScan = 0;
        hr = get_aime(0, luid, 10);
        CHECK(hr == S_FALSE, "aime_io_nfc_get_aime_id returns S_FALSE once cardScan=0");
    } else {
        printf("through the DLL: lever=%d left=0x%02x right=0x%02x op=0x%02x aime_hr=0x%08x luid=",
            lever, left, right, op, (unsigned)hr);
        for (int i = 0; i < 10; i++) printf("%02x", luid[i]);
        printf("\n");
    }

    printf("\n%s (%d failure%s)\n", fails ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}

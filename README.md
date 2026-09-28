# GekiPad

Use an iPad (over a USB cable) as the lever + buttons for **ONGEKI on PC** running with segatools, with the game
picture streamed back onto the iPad.

> **Status:** built and unit-tested against the documented segatools API and cross-checked line-by-line against a
> real ONGEKI ReFresh 1.51.00 install's own `segatools.ini`/`mu3.ini`/`start.bat` and against segatools' own source
> (`mu3io.h`, `aimeio.h`, `mu3hook/mu3-dll.c`, `mu3hook/io4.c`, `iccard/aime.c`). Not yet run against the live game
> or a real iPad (no chance to launch it yet) - the couple of things that genuinely can't be settled without doing
> that are marked **CONFIRM** below.

> Not affiliated with SEGA. No game files, keychips or keys are included or needed from this repo. You must supply
> your own legally obtained game setup. This project only emulates the *input device*.

## What ONGEKI's cabinet actually has

No touch panel. A spring-free lever (it holds wherever you last moved it, it does not recentre itself) and two
button clusters either side of it, each with 3 round buttons (red/green/blue), a SIDE button and a MENU button, plus
the usual Test/Service/Coin and a card reader. The screen itself is portrait (1080x1920) - real cabs rotate the
physical monitor; this project just opens the window at that size directly instead.

## How it works

Unlike maimai (a serial touch-panel protocol), ONGEKI's segatools input is a plain DLL API (`mu3io.h` / `aimeio.h`)
that the game calls directly, in-process. So the architecture here follows the same pattern as this project's
CHUNITHM Brokenithm setup rather than the maimai one:

```
iPad (GekiPad app) --USB/usbmuxd--> GekiBridge.exe --shared memory--> GekiIo.dll (loaded inside the game)
      lever + buttons -------------------------------------------->   answers mu3io.h / aimeio.h calls
      coin ------------------------------------------------------->   GekiBridge.exe presses the coin key directly
      game picture    <--------------------------------------------   GDI screen capture, JPEG over the same link
```

- **GekiIo.dll** (`pc/dll/GekiIo.cpp`, C++) is loaded by segatools itself (`[mu3io] path=` / `[aimeio] path=`) and
  answers the game's calls by reading a small named-shared-memory block (`Local\GekiPadShared`). It never talks to
  the iPad and has no coin logic at all (see below). Verified with a standalone test (`pc/dll/dlltest.cpp`) that
  writes the shared block and calls every exported function through a real `LoadLibrary`/`GetProcAddress`, exactly
  as segatools would - every field round-trips correctly, including a real Aime card id (see below).
- **GekiBridge.exe** (`pc/GekiBridge.cs`, C#) is the only thing that talks to the iPad (USB via usbmuxd, no Wi-Fi in
  this version). It fills the shared-memory block, presses the coin key, and streams the game's picture back,
  reusing the JPEG-over-USB approach from the maimai project - simplified, since ONGEKI's window is captured in
  full (no crop/mask needed, just scaled to a target width). Verified end-to-end with a fake iPad client: sent
  lever/button/card messages and a real Aime card id through the actual DLL, confirmed every value round-trips.
- **GekiPad app** (`Sources/*.swift`) is the iPad side: a lever strip (holds position, no spring-back), the two
  button clusters, small Test/Service/Coin/Card/Settings/Video buttons, and the same kind of Settings menu as the
  maimai project (picture quality, button opacity, lever sensitivity, tap sound, latency readout, custom
  background). Landscape only - the portrait game picture is letterboxed in the middle, same idea as a real cab's
  tall screen sitting above a wide control panel. Built with GitHub Actions; **not yet installed on a real iPad**.

## What's now confirmed against a real install

(checked against `.../O.N.G.E.K.I ReFresh (2025) [Sega ALLS]/SDDT 1.51.00/package/`)

- **Executable:** `mu3.exe`. **Hook DLL:** `mu3hook.dll`. **ini sections:** `[mu3io] path=` / `[aimeio] path=` -
  exactly as this project assumed.
- **`[mu3io]`/`[aimeio]` fully replace segatools' built-in input** the moment `path=` is non-empty (checked
  `mu3hook/mu3-dll.c`: it binds all five `mu3_io_*` function pointers to your DLL, no partial fallback).
- **Coin has no mu3io.h entry point**, and checking `mu3hook/io4.c` shows why: coin/test/service normally come from
  a *separate*, always-on keyboard hook (segatools' generic io4-board emulation, which - per this project's maimai
  work - polls `GetAsyncKeyState`, not per-window input) that exists independently of which `[mu3io]` DLL is
  active. So `GekiBridge.exe` presses the coin key directly (`[io4] coin=0x72` / F3 in the real install's own ini,
  same default this project's maimai bridge already used) rather than routing it through the DLL at all.
  **Test/service** *are* part of mu3io.h (`mu3_io_get_opbtns`) and go through the DLL as designed.
- **Aime card id format was wrong in the first version of this DLL** - it assumed 20 hex characters. Checking
  segatools' `iccard/aime.c` (`aime_card_populate`, which validates the 10-byte luid as binary-coded decimal, every
  nibble 0-9) shows it's actually the **20 decimal digits from `aime.txt`, packed two digits per byte**. Fixed, and
  verified against the real install's own `DEVICE\aime.txt` (`89013861175251191402`) - it packs cleanly and
  round-trips byte-exact through the whole pipeline in testing.
- **The game renders portrait (1080x1920)**, confirmed from `start.bat`'s launch flags. The stock launcher runs it
  **exclusive fullscreen** and physically rotates the display (`RotateDisplay.exe`/`RotateScreen.exe`) to compensate
  for a landscape monitor. Exclusive fullscreen can't be GDI-captured, so this project's launcher instead runs it
  **windowed** (`-screen-fullscreen 0 -popupwindow`) at the same 1080x1920, exactly like this project's maimai
  setup - no display rotation needed at all.
- **AM Daemon** takes 3 config files here (`config_common.json config_server.json config_client.json`), not 4.

## CONFIRM once you can actually launch it

- **Test/service really routing through the DLL as expected** once `[mu3io] path=` is set - very likely correct
  per `mu3-dll.c`, but only actually watching the game respond will settle it.
- **The lever's centre/range the game's calibration screen wants** - the app sends -32767..32767 with 0 as centre,
  matching mu3io.h's guidance; adjust in `GekiPadView.swift`'s `updateLever` if the game wants something else.
- **The window title** GekiBridge searches for (`mu3`, matching the exe name) - hasn't been seen on screen yet.

## Setup

1. **Build `GekiIo.dll`** with MinGW-w64 (a real C compiler is required - unlike this project's C#-only maimai
   pieces, this DLL must be native code because segatools loads it directly). **Note for whoever builds this next:**
   in this environment, invoking g++ through a Bash/Git-Bash tool silently failed (it couldn't spawn cc1plus.exe,
   no error text, just a bad exit code) - PowerShell worked fine. If you hit a compiler that "does nothing," try a
   different shell before assuming the source is broken.
   ```
   g++ -shared -O2 -std=c++17 -o GekiIo.dll pc/dll/GekiIo.cpp -lgdi32
   ```
2. **Build the bridge**: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /optimize /r:System.Drawing.dll /out:GekiBridge.exe pc\GekiBridge.cs`
3. Copy `GekiIo.dll`, `GekiBridge.exe` and `pc/start_gekipad.bat` into your segatools `package` folder (next to
   `mu3.exe`/`segatools.ini`).
4. In `segatools.ini`:
   ```
   [mu3io]
   path=GekiIo.dll
   [aimeio]
   path=GekiIo.dll
   ```
5. **iPad**: build `GekiPad.ipa` via this repo's GitHub Action (Actions tab -> latest run -> `GekiPad-ipa` artifact),
   sideload it (Sideloadly/AltStore), trust the developer certificate (Settings > General > VPN & Device Management),
   turn on Developer Mode if asked (iOS 16+).
6. Open GekiPad on the iPad, plugged in and unlocked. Run `start_gekipad.bat`.
7. Bridge log: `GekiBridge.log`, next to `GekiBridge.exe`.

## Side notes

- **Lever/buttons/test/service need no window-focus trick** - they go straight through the DLL API the game calls
  itself, not simulated key presses, so they work the instant the game reads them regardless of which window is in
  front. Only the coin key (see above) has that dependency, since it's the one input that had to fall back to a key
  press, exactly like this project's maimai coin button.
- **Lever feel**: the app strip holds its position when you lift your finger (no spring-back). A sensitivity slider
  in Settings scales how far you need to drag for a full swing.
- **Video**: full window capture, scaled to a target width while keeping the game's own (portrait) aspect ratio.

## Not done yet / ideas

Wi-Fi fallback page, FeliCa card support, adaptive video quality, per-cluster button remapping.

## Repository layout

| Path | What |
|---|---|
| `Sources/`, `project.yml` | iPad app (Swift, XcodeGen) |
| `.github/workflows/build.yml` | Builds an unsigned `GekiPad.ipa` on GitHub |
| `pc/dll/GekiIo.cpp` | segatools `mu3io`/`aimeio` provider DLL, loaded into the game |
| `pc/dll/dlltest.cpp` | standalone test harness for the DLL (not shipped) |
| `pc/GekiBridge.cs` | USB link + shared memory writer + coin key press + video capture |
| `pc/start_gekipad.bat` | Launcher, based on a real install's own `start.bat` |

## Protocol (for hackers)

Shared memory (`Local\GekiPadShared`, 23 bytes, `#pragma pack(1)`): `uint32 magic('GKPD'), uint8 version, int16
lever, uint8 leftBtn, rightBtn, opBtn, reserved, cardScan, uint8[10] aimeLuid, uint8 connected`. `leftBtn`/`rightBtn`
use `MU3_IO_GAMEBTN_*` bits (1/2/4/8/0x10 = btn1/btn2/btn3/side/menu), `opBtn` uses `MU3_IO_OPBTN_*` (1/2 =
test/service). `aimeLuid` is BCD: each byte is two decimal digits from `aime.txt` (e.g. digits `89` -> byte `0x89`).

App <-> bridge (TCP 24880 over usbmuxd). App to PC, text lines: `L<signed int>` lever, `G` + 10 bits (left
btn1,btn2,btn3,side,menu, then right the same), `X` + 4 bits (test,service,coin,card), `V<width>,<quality>` (`V0`
= off), `P<id>` ping. PC to app: `[uint32 LE length][bytes]`; a length with the top bit set is a short text control
message (`O<id>` ping answer, `T<ms>,<fps>` capture timing), otherwise the bytes are a JPEG picture.

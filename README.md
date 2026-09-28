# GekiPad

Use an iPad (over a USB cable) as the lever + buttons for **ONGEKI on PC** running with segatools, with the game
picture streamed back onto the iPad.

> **Status: built and unit-tested against the documented segatools API, but not yet run against a real ONGEKI
> install** (none was available while building this). The pieces most likely to need a fix once you try it are
> marked **CONFIRM** below - they're the parts no amount of testing without the real game could settle.

> Not affiliated with SEGA. No game files, keychips or keys are included or needed from this repo. You must supply
> your own legally obtained game setup. This project only emulates the *input device*.

## What ONGEKI's cabinet actually has

No touch panel. A spring-free lever (it holds wherever you last moved it, it does not recentre itself) and two
button clusters either side of it, each with 3 round buttons (red/green/blue), a SIDE button and a MENU button, plus
the usual Test/Service/Coin and a card reader.

## How it works

Unlike maimai (a serial touch-panel protocol), ONGEKI's segatools input is a plain DLL API (`mu3io.h` / `aimeio.h`,
confirmed against [djhackersdev/segatools](https://github.com/djhackersdev/segatools/blob/master/mu3io/mu3io.h)) that
the game calls directly, in-process. So the architecture here follows the same pattern as this project's CHUNITHM
Brokenithm setup rather than the maimai one:

```
iPad (GekiPad app) --USB/usbmuxd--> GekiBridge.exe --shared memory--> GekiIo.dll (loaded inside the game)
      lever + buttons -------------------------------------------->   answers mu3io.h / aimeio.h calls
      game picture    <--------------------------------------------   GDI screen capture, JPEG over the same link
```

- **GekiIo.dll** (`pc/dll/GekiIo.cpp`, C++) is loaded by segatools itself (`[mu3io] path=` / `[aimeio] path=`) and
  answers the game's calls by reading a small named-shared-memory block (`Local\GekiPadShared`). It never talks to
  the iPad. Verified with a standalone test (`pc/dll/dlltest.cpp`) that writes the shared block and calls every
  exported function through a real `LoadLibrary`/`GetProcAddress`, exactly as segatools would - all fields round-trip
  correctly. mu3io.h has no coin function, so coin is injected as a configurable key press (`gekipad.cfg`), only
  while the game window is in front (same safety rule as this project's maimai bridge).
- **GekiBridge.exe** (`pc/GekiBridge.cs`, C#) is the only thing that talks to the iPad (USB via usbmuxd, no Wi-Fi in
  this version). It fills the shared-memory block and streams the game's picture back, reusing the same JPEG-over-
  USB approach as the maimai project, simplified since ONGEKI's screen is a normal 16:9 window with no crop/mask
  needed. Verified end-to-end with a fake iPad client: sent lever/button/card messages, confirmed
  `dlltest.exe --readonly` reads back the exact values through the DLL, and confirmed a live screen capture
  (of a stand-in window) round-trips into a valid JPEG.
- **GekiPad app** (`Sources/*.swift`) is the iPad side: a lever strip, the two button clusters, small
  Test/Service/Coin/Card/Settings/Video buttons, and the same kind of Settings menu (picture quality, button
  opacity, lever sensitivity, tap sound, latency readout, custom background) as the maimai project. Landscape only.
  Built with GitHub Actions the same way; **not yet installed on a real iPad**.

## CONFIRM before/while setting up

- **`WindowTitle=MU3`** in `gekipad.cfg` (and `--window MU3` in the launcher) - an unverified guess at the game's
  window title. Fix it once you see the real title, or coin presses and video capture won't find the window.
- **The `[mu3io]`/`[aimeio]` ini section names and your segatools fork's exact hook name** - written against the
  `mu3io.h`/`aimeio.h` from djhackersdev/segatools; confirm your fork matches.
- **Coin.** Not part of mu3io.h, so this project guesses it's a keyboard key elsewhere in your segatools stack
  (`CoinKey=0x72` / F3, same as this project's maimai setup) - check your actual config.
- **Aime card ID format.** This sends the classic 10-byte `luid` (`aime_io_nfc_get_aime_id`); FeliCa `IDm` (
  `aime_io_nfc_get_felica_id`) is not implemented. If your setup expects FeliCa, that function needs filling in.
- **The lever's actual centre/range on your build** - the app sends -32767..32767 with 0 as centre, matching the
  header's guidance ("the centre position should be equal to or close to zero"); if the game's own calibration
  screen wants something else, adjust in `GekiPadView.swift`'s `updateLever`.

## Setup (once the above is confirmed)

1. **Build `GekiIo.dll`** with MinGW-w64 (a real C compiler is required - unlike this project's C#-only maimai
   pieces, this DLL must be native code because segatools loads it directly):
   ```
   g++ -shared -O2 -std=c++17 -o GekiIo.dll pc/dll/GekiIo.cpp -lgdi32
   ```
2. **Build the bridge**: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /optimize /r:System.Drawing.dll /out:GekiBridge.exe pc\GekiBridge.cs`
3. Put `GekiIo.dll`, `GekiBridge.exe`, `gekipad.cfg` together in one folder (e.g. alongside your segatools `Package`
   folder). Edit `gekipad.cfg`.
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
6. Open GekiPad on the iPad, plugged in and unlocked. Run `start_gekipad.bat` (edit it first - see the comments
   inside) or start `GekiBridge.exe` yourself, then launch the game the way your segatools loader normally does.
7. Bridge log: `GekiBridge.log`, next to `GekiBridge.exe`.

## Side notes

- **Coin/card need no window focus trick on the input side** - unlike maimai, the lever and buttons go straight
  through the DLL API, not simulated key presses, so they work the instant the game reads them, with no dependency
  on which window is in front. Only the coin key (see above) has that dependency, because it's the one input that
  had to fall back to a key press.
- **Lever feel**: the app strip holds its position when you lift your finger (no spring-back), matching the real
  lever. A sensitivity slider in Settings scales how far you need to drag for a full swing.
- **Video**: full window capture, scaled to a target width while keeping the game's own aspect ratio - no crop, no
  window-resize trick (ONGEKI doesn't have maimai's "window taller than the monitor" problem).

## Not done yet / ideas

Wi-Fi fallback page, FeliCa card support, adaptive video quality, per-cluster button remapping.

## Repository layout

| Path | What |
|---|---|
| `Sources/`, `project.yml` | iPad app (Swift, XcodeGen) |
| `.github/workflows/build.yml` | Builds an unsigned `GekiPad.ipa` on GitHub |
| `pc/dll/GekiIo.cpp` | segatools `mu3io`/`aimeio` provider DLL, loaded into the game |
| `pc/dll/dlltest.cpp` | standalone test harness for the DLL (not shipped) |
| `pc/GekiBridge.cs` | USB link + shared memory writer + video capture |
| `pc/gekipad.cfg`, `pc/start_gekipad.bat` | DLL config and an example launcher |

## Protocol (for hackers)

Shared memory (`Local\GekiPadShared`, 23 bytes, `#pragma pack(1)`): `uint32 magic('GKPD'), uint8 version, int16
lever, uint8 leftBtn, rightBtn, opBtn, coinHeld, cardScan, uint8[10] aimeLuid, uint8 connected`. `leftBtn`/`rightBtn`
use `MU3_IO_GAMEBTN_*` bits (1/2/4/8/0x10 = btn1/btn2/btn3/side/menu), `opBtn` uses `MU3_IO_OPBTN_*` (1/2 =
test/service).

App <-> bridge (TCP 24880 over usbmuxd). App to PC, text lines: `L<signed int>` lever, `G` + 10 bits (left
btn1,btn2,btn3,side,menu, then right the same), `X` + 4 bits (test,service,coin,card), `V<width>,<quality>` (`V0`
= off), `P<id>` ping. PC to app: `[uint32 LE length][bytes]`; a length with the top bit set is a short text control
message (`O<id>` ping answer, `T<ms>,<fps>` capture timing), otherwise the bytes are a JPEG picture.
